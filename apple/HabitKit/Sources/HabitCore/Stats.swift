/// Ob Streaks in Tagen oder in Wochen gezählt werden.
///
/// `timesPerWeek` wird wochenweise bewertet: „3× pro Woche" hat keine
/// Tages-Streaks, sondern Wochen-Streaks.
public enum StreakUnit: String, Codable, Sendable, Hashable {
    case days, weeks
}

public struct HabitStats: Hashable, Sendable {
    public let currentStreak: Int
    public let longestStreak: Int
    public let streakUnit: StreakUnit
    /// Erfüllt geteilt durch bewertet. `nil`, wenn nichts zu bewerten war.
    public let completionRate: Double?
    public let completedCount: Int
    public let evaluatedCount: Int
    /// Status jedes Tages im angefragten Zeitraum — Grundlage für Heatmap und Kalender.
    public let days: [CalendarDate: DayStatus]
    /// Je Wochentag der Anteil erledigter an geplanten Tagen. Fehlt ein Wochentag,
    /// gab es dafür keine Datengrundlage.
    public let weekdayBreakdown: [Weekday: Double]
}

/// Zusammengeführte Sicht auf Einträge und Ausnahmen eines Habits.
struct DayIndex {
    let entries: [CalendarDate: Entry]
    let exceptions: [CalendarDate: DayException]

    init(habit: Habit, entries: [Entry], exceptions: [DayException]) {
        var e: [CalendarDate: Entry] = [:]
        for entry in entries where entry.deletedAt == nil && entry.habitId == habit.id {
            e[entry.date] = entry
        }
        self.entries = e

        // Eine habit-spezifische Ausnahme schlägt die globale desselben Tages:
        // ein bewusster Ruhetag für genau diesen Habit ist die genauere Aussage.
        var x: [CalendarDate: DayException] = [:]
        for ex in exceptions where ex.deletedAt == nil {
            guard ex.habitId == nil || ex.habitId == habit.id else { continue }
            if let existing = x[ex.date], existing.habitId != nil, ex.habitId == nil { continue }
            x[ex.date] = ex
        }
        self.exceptions = x
    }
}

/// Vollständige Auswertung eines Habits über einen Zeitraum.
///
/// `today` wird übergeben statt ermittelt — die Domäne kennt keine Systemuhr,
/// dadurch sind alle Ergebnisse reproduzierbar und testbar.
public func stats(
    for habit: Habit,
    entries: [Entry],
    exceptions: [DayException] = [],
    from: CalendarDate,
    to: CalendarDate,
    today: CalendarDate
) -> HabitStats {
    let index = DayIndex(habit: habit, entries: entries, exceptions: exceptions)
    let range = from.through(to)

    var days: [CalendarDate: DayStatus] = [:]
    for date in range {
        days[date] = status(for: habit, entry: index.entries[date],
                            exception: index.exceptions[date], on: date, today: today)
    }

    // Welche Regel gerade gilt, entscheidet über die Zähleinheit. Bei einem
    // Zeitplanwechsel mitten im Zeitraum wird also nach dem aktuellen Modus
    // bewertet — das ist die Frage, die der Nutzer beim Draufschauen stellt.
    let anchor = min(to, today)
    let unit: StreakUnit = (habit.rule(on: anchor)?.schedule.weeklyTarget != nil)
        ? .weeks : .days

    let weekday = weekdayBreakdown(habit: habit, days: days, range: range, today: today)

    switch unit {
    case .days:
        let evaluated = range.filter { $0 <= today && (days[$0]?.countsTowardRate ?? false) }
        let completed = evaluated.filter { days[$0]?.isCompleted ?? false }
        return HabitStats(
            currentStreak: currentDayStreak(days: days, from: from, anchor: anchor, today: today),
            longestStreak: longestDayStreak(days: days, range: range, anchor: anchor),
            streakUnit: .days,
            completionRate: evaluated.isEmpty ? nil : Double(completed.count) / Double(evaluated.count),
            completedCount: completed.count,
            evaluatedCount: evaluated.count,
            days: days,
            weekdayBreakdown: weekday
        )

    case .weeks:
        let weeks = weekSummaries(habit: habit, days: days, from: from, to: to, today: today)
        // Nur abgeschlossene Wochen gehen in die Quote ein — eine angebrochene
        // Woche würde sie sonst systematisch nach unten ziehen.
        let finished = weeks.filter { $0.isOver }
        let hit = finished.filter { $0.isFulfilled }
        return HabitStats(
            currentStreak: currentWeekStreak(weeks: weeks),
            longestStreak: longestWeekStreak(weeks: weeks),
            streakUnit: .weeks,
            completionRate: finished.isEmpty ? nil : Double(hit.count) / Double(finished.count),
            completedCount: hit.count,
            evaluatedCount: finished.count,
            days: days,
            weekdayBreakdown: weekday
        )
    }
}

// MARK: - Tages-Streaks

private func currentDayStreak(
    days: [CalendarDate: DayStatus],
    from: CalendarDate,
    anchor: CalendarDate,
    today: CalendarDate
) -> Int {
    var streak = 0
    var date = anchor
    while date >= from {
        switch days[date] {
        case .completed:
            streak += 1
        case .missed:
            return streak
        case .partial:
            // Nur der laufende Tag kann `partial` sein; er ist noch nicht verloren.
            if date != today { return streak }
        case .excepted, .notScheduled, .future, .none:
            break   // unterbricht nicht und verlängert nicht
        }
        date = date.adding(days: -1)
    }
    return streak
}

private func longestDayStreak(
    days: [CalendarDate: DayStatus],
    range: [CalendarDate],
    anchor: CalendarDate
) -> Int {
    var best = 0
    var run = 0
    for date in range where date <= anchor {
        switch days[date] {
        case .completed:
            run += 1
            best = max(best, run)
        case .missed:
            run = 0
        case .partial, .excepted, .notScheduled, .future, .none:
            break
        }
    }
    return best
}

// MARK: - Wochen-Streaks (timesPerWeek)

struct WeekSummary {
    let start: CalendarDate
    let completed: Int
    let required: Int
    /// Geplante Tage, die noch kommen — nur in der laufenden Woche > 0.
    let remaining: Int
    let isOver: Bool
    /// Komplett pausierte oder außerhalb des Habit-Zeitraums liegende Woche.
    let isVoid: Bool

    var isFulfilled: Bool { completed >= required }
    /// Ob das Wochenziel rechnerisch noch erreichbar ist.
    var isStillPossible: Bool { completed + remaining >= required }
}

func weekSummaries(
    habit: Habit,
    days: [CalendarDate: DayStatus],
    from: CalendarDate,
    to: CalendarDate,
    today: CalendarDate
) -> [WeekSummary] {
    var result: [WeekSummary] = []
    var weekStart = from.weekStart
    let last = min(to, today).weekStart

    while weekStart <= last {
        let weekDays = weekStart.through(weekStart.adding(days: 6))
        var scheduled = 0
        var completed = 0
        var remaining = 0

        for date in weekDays {
            guard let status = days[date] else { continue }
            switch status {
            case .completed:
                scheduled += 1
                completed += 1
            case .missed, .excepted(.frozen):
                scheduled += 1
            case .partial:
                // Heute: zählt zur Woche und ist noch erreichbar.
                scheduled += 1
                remaining += 1
            case .future:
                if habit.isScheduled(on: date) { scheduled += 1; remaining += 1 }
            case .notScheduled:
                // Bei timesPerWeek ist jeder Tag im aktiven Zeitraum planbar;
                // `notScheduled` heißt hier: außerhalb des Habits oder pausiert.
                if habit.isScheduled(on: date) { scheduled += 1 }
            case .excepted:
                break   // paused / skipped: nimmt den Tag aus der Woche
            }
        }

        let n = habit.rule(on: weekStart)?.schedule.weeklyTarget
            ?? habit.rule(on: min(weekStart.adding(days: 6), to))?.schedule.weeklyTarget
            ?? 0

        // Pausierte Tage senken das Wochenziel anteilig — nach einer halben
        // Urlaubswoche noch drei Einheiten zu verlangen wäre unfair.
        let required = scheduled == 0 ? 0 : max(1, Int((Double(n) * Double(scheduled) / 7.0).rounded(.down)))

        result.append(WeekSummary(
            start: weekStart,
            completed: completed,
            required: required,
            remaining: remaining,
            isOver: weekStart.adding(days: 6) < today,
            isVoid: scheduled == 0 || n == 0
        ))
        weekStart = weekStart.adding(days: 7)
    }
    return result
}

private func currentWeekStreak(weeks: [WeekSummary]) -> Int {
    var streak = 0
    for week in weeks.reversed() {
        if week.isVoid { continue }             // pausierte Woche überspringt
        if week.isFulfilled { streak += 1; continue }
        if !week.isOver && week.isStillPossible { continue }   // läuft noch
        return streak
    }
    return streak
}

private func longestWeekStreak(weeks: [WeekSummary]) -> Int {
    var best = 0
    var run = 0
    for week in weeks {
        if week.isVoid { continue }
        if week.isFulfilled {
            run += 1
            best = max(best, run)
        } else if week.isOver {
            run = 0
        } else if !week.isStillPossible {
            run = 0
        }
    }
    return best
}

// MARK: - Wochentage

/// Anteil erledigter an geplanten Tagen je Wochentag.
///
/// Nenner sind alle vergangenen Tage, an denen der Habit planbar war — bei
/// `timesPerWeek` also jeder Tag im aktiven Zeitraum. Dadurch beantwortet die
/// Auswertung für beide Zeitplan-Arten dieselbe Frage: „an welchem Wochentag
/// klappt es?"
func weekdayBreakdown(
    habit: Habit,
    days: [CalendarDate: DayStatus],
    range: [CalendarDate],
    today: CalendarDate
) -> [Weekday: Double] {
    var total: [Weekday: Int] = [:]
    var hit: [Weekday: Int] = [:]

    for date in range where date < today {
        guard let status = days[date] else { continue }
        if case .excepted(let kind) = status, kind.removesDayFromSchedule { continue }
        guard habit.isScheduled(on: date) else { continue }
        total[date.weekday, default: 0] += 1
        if status.isCompleted { hit[date.weekday, default: 0] += 1 }
    }

    return total.reduce(into: [:]) { result, pair in
        result[pair.key] = Double(hit[pair.key] ?? 0) / Double(pair.value)
    }
}
