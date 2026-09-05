import Foundation

/// Ein Tag über alle Habits hinweg zusammengefasst.
public struct DaySummary: Hashable, Sendable {
    public let date: CalendarDate
    /// Wie viele Habits an diesem Tag erfüllt waren.
    public let completed: Int
    /// Wie viele an diesem Tag zählten — siehe `overview(...)` zur Definition.
    public let scheduled: Int

    public init(date: CalendarDate, completed: Int, scheduled: Int) {
        self.date = date
        self.completed = completed
        self.scheduled = scheduled
    }

    /// Anteil erledigter Habits, `nil` wenn nichts anstand.
    ///
    /// Ein Tag ohne Plan ist ausdrücklich nicht „0 %" — er hat kein Ergebnis.
    public var share: Double? {
        scheduled == 0 ? nil : Double(completed) / Double(scheduled)
    }

    /// Alles erledigt, was anstand. Tage ohne Plan zählen nicht als perfekt.
    public var isPerfect: Bool { scheduled > 0 && completed == scheduled }
}

/// Fasst alle Habits je Tag zusammen — Grundlage für die gesammelte Heatmap.
///
/// **Was in den Nenner kommt**, ist die einzige interessante Entscheidung hier.
/// Ein `timesPerWeek`-Habit ist an jedem Tag *planbar*, aber an keinem
/// verpflichtend. Zählte er täglich mit, würde ein 3×/Woche-Habit an vier von
/// sieben Tagen als „nicht erfüllt" erscheinen und die Übersicht dauerhaft
/// eintrüben, obwohl das Wochenziel erreicht ist.
///
/// Deshalb zählt ein Habit an einem Tag, wenn er dort **verpflichtend** war
/// oder wenn er **erfüllt** wurde. Ein an diesem Tag erledigter
/// `timesPerWeek`-Habit geht also in Zähler und Nenner ein, ein nicht
/// erledigter in keinen von beiden. Der Anteil kann dadurch nie über 100 %
/// steigen, und freiwillig Erledigtes wird belohnt statt ignoriert.
///
/// Pausierte und übersprungene Tage fallen für den jeweiligen Habit heraus,
/// eingefrorene bleiben im Nenner — ein Freeze rettet den Streak, schönt die
/// Statistik aber nicht.
public func overview(
    habits: [Habit],
    entries: [Entry],
    exceptions: [DayException] = [],
    from: CalendarDate,
    to: CalendarDate,
    today: CalendarDate
) -> [CalendarDate: DaySummary] {
    // Einträge und Ausnahmen einmal indizieren statt je Tag zu filtern.
    var entriesByHabit: [UUID: [CalendarDate: Entry]] = [:]
    for entry in entries where entry.deletedAt == nil {
        entriesByHabit[entry.habitId, default: [:]][entry.date] = entry
    }

    var perHabit: [UUID: [CalendarDate: DayException]] = [:]
    var global: [CalendarDate: DayException] = [:]
    for exception in exceptions where exception.deletedAt == nil {
        if let habitId = exception.habitId {
            perHabit[habitId, default: [:]][exception.date] = exception
        } else {
            global[exception.date] = exception
        }
    }

    var result: [CalendarDate: DaySummary] = [:]

    for date in from.through(to) {
        var completed = 0
        var scheduled = 0

        for habit in habits {
            // Eine habit-spezifische Ausnahme ist die genauere Aussage als eine globale.
            let exception = perHabit[habit.id]?[date] ?? global[date]

            let dayStatus = status(for: habit,
                                   entry: entriesByHabit[habit.id]?[date],
                                   exception: exception,
                                   on: date, today: today)

            if dayStatus.isCompleted {
                completed += 1
                scheduled += 1
            } else if habit.isRequired(on: date),
                      !(exception?.kind.removesDayFromSchedule ?? false) {
                scheduled += 1
            }
        }

        result[date] = DaySummary(date: date, completed: completed, scheduled: scheduled)
    }

    return result
}

/// Kennzahlen über alle Habits für die Kopfzeile der Übersicht.
public struct OverviewStats: Hashable, Sendable {
    /// Tage, an denen alles Anstehende erledigt war.
    public let perfectDays: Int
    /// Tage mit Plan, unabhängig vom Ergebnis.
    public let daysWithPlan: Int
    /// Summe aller Erledigungen im Zeitraum.
    public let totalCompletions: Int
    /// Aktuelle Serie perfekter Tage, endend heute.
    public let perfectStreak: Int
    /// Höchste Zahl an Erledigungen an einem Tag — Maßstab für die Farbskala.
    public let busiestDay: Int
}

public func overviewStats(
    summaries: [CalendarDate: DaySummary],
    from: CalendarDate,
    to: CalendarDate,
    today: CalendarDate
) -> OverviewStats {
    let past = from.through(min(to, today)).compactMap { summaries[$0] }

    var streak = 0
    var date = min(to, today)
    while date >= from, let summary = summaries[date] {
        if summary.isPerfect {
            streak += 1
        } else if summary.scheduled == 0 {
            // Ein Tag ohne Plan unterbricht nichts — es gab nichts zu verpassen.
        } else if date == today && summary.completed < summary.scheduled {
            // Der laufende Tag ist noch nicht verloren.
        } else {
            break
        }
        date = date.adding(days: -1)
    }

    return OverviewStats(
        perfectDays: past.filter(\.isPerfect).count,
        daysWithPlan: past.filter { $0.scheduled > 0 }.count,
        totalCompletions: past.reduce(0) { $0 + $1.completed },
        perfectStreak: streak,
        busiestDay: past.map(\.completed).max() ?? 0
    )
}


// MARK: - Farbstufen

/// Wonach sich die Sättigung eines Tages in der Übersichts-Heatmap richtet.
public enum IntensityScale: String, CaseIterable, Sendable, Hashable, Codable {
    /// Wie viele Habits erledigt wurden — das GitHub-Vorbild.
    case count
    /// Welcher Anteil des an diesem Tag Anstehenden erledigt wurde.
    case share
}

/// In welche von fünf Farbstufen ein Tag fällt: 0 = leer, 4 = am kräftigsten.
///
/// Bewusst hier und nicht in der View: die WebApp muss dieselbe Einstufung
/// treffen, sonst zeigen Mac und Browser für denselben Bestand verschiedene
/// Bilder. Wie Stufe 3 dann *aussieht*, ist Sache der jeweiligen Oberfläche.
///
/// `busiestDay` ist die Bezugsgröße für `.count` — die höchste Zahl an
/// Erledigungen im gezeigten Zeitraum. Damit skaliert sich das Bild selbst:
/// wer sechs Habits führt, bekommt dieselbe Bandbreite wie jemand mit zweien.
public func intensityLevel(
    _ summary: DaySummary,
    scale: IntensityScale,
    busiestDay: Int
) -> Int {
    switch scale {
    case .count:
        guard busiestDay > 0, summary.completed > 0 else { return 0 }
        let ratio = Double(summary.completed) / Double(busiestDay)
        return min(4, max(1, Int(ceil(ratio * 4))))
    case .share:
        guard let share = summary.share, share > 0 else { return 0 }
        return min(4, max(1, Int(ceil(share * 4))))
    }
}


// MARK: - Ausschnitt

/// Welcher Zeitraum in der Übersicht gezeigt wird.
public enum OverviewSpan: String, CaseIterable, Sendable, Hashable, Codable {
    case week, month, year

    /// Der abgedeckte Zeitraum um einen Ankertag herum.
    ///
    /// Woche und Monat rasten am Kalender ein (Montag bis Sonntag, Erster bis
    /// Letzter). Das Jahr sind die 53 Wochen, die auf die Ankerwoche enden —
    /// dieselbe Bandbreite, die das GitHub-Vorbild zeigt, und immer an einer
    /// Wochengrenze, damit die sieben Zeilen der Heatmap aufgehen.
    public func range(containing anchor: CalendarDate) -> (from: CalendarDate, to: CalendarDate) {
        switch self {
        case .week:  (anchor.weekStart, anchor.weekEnd)
        case .month: (anchor.monthStart, anchor.monthEnd)
        case .year:  (anchor.weekStart.adding(days: -7 * 52), anchor.weekEnd)
        }
    }

    /// Der Anker, `steps` Ausschnitte weiter (negativ: zurück).
    public func shift(_ anchor: CalendarDate, by steps: Int) -> CalendarDate {
        switch self {
        case .week:  anchor.adding(days: 7 * steps)
        case .month: anchor.addingMonths(steps)
        case .year:  anchor.addingMonths(12 * steps)
        }
    }

    /// Wie viele Tage der Ausschnitt höchstens umfasst — für das Nachladen.
    public var maximumDays: Int {
        switch self {
        case .week: 7
        case .month: 31
        case .year: 371
        }
    }
}
