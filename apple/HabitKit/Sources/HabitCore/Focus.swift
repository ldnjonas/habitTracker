import Foundation

/// Ein selbst gesetzter Zeitraum, in dem lückenlos alles erfüllt werden soll.
///
/// Der Streak fragt „wie lange schon?", der Fokus fragt „schaffe ich *diese*
/// sieben Tage?". Das ist ein anderes Versprechen: es hat einen Anfang, ein
/// Ende und ein Ergebnis — und man kann es verlieren, ohne alles zu verlieren.
///
/// **Gespeichert wird nur die Absicht, nie das Ergebnis.** Ob ein Lauf
/// durchgezogen wurde, ergibt sich aus den Einträgen. Ein gespeichertes
/// „geschafft" würde von ihnen abdriften, sobald ein Tag nachträglich korrigiert
/// wird — und wäre dann eine Auszeichnung für etwas, das nicht mehr stimmt.
public struct FocusRun: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var userId: String
    /// Frei wählbar; ohne Angabe zeigt die Oberfläche „7-Tage-Fokus".
    public var title: String?
    public var startsOn: CalendarDate
    /// Einschließlich — ein 7-Tage-Fokus ab Montag endet am Sonntag.
    public var endsOn: CalendarDate
    /// Leer heißt: alle Habits, auch später angelegte.
    ///
    /// Bewusst eine Momentaufnahme der Absicht und kein Fremdschlüssel: ein
    /// später gelöschter Habit soll den Verlaufseintrag nicht mitreißen.
    public var habitIds: [UUID]
    /// Selbst beendet. Ehrlicher, als einen Lauf still verrotten zu lassen.
    public var abandonedOn: CalendarDate?
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(
        id: UUID = UUID(),
        userId: String = Habit.localUserId,
        title: String? = nil,
        startsOn: CalendarDate,
        endsOn: CalendarDate,
        habitIds: [UUID] = [],
        abandonedOn: CalendarDate? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.userId = userId
        self.title = title
        self.startsOn = startsOn
        self.endsOn = endsOn
        self.habitIds = habitIds
        self.abandonedOn = abandonedOn
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    public var totalDays: Int { startsOn.days(until: endsOn) + 1 }

    public func covers(_ date: CalendarDate) -> Bool {
        date >= startsOn && date <= endsOn
    }

    /// Ob dieser Habit zum Lauf gehört.
    public func includes(habitId: UUID) -> Bool {
        habitIds.isEmpty || habitIds.contains(habitId)
    }

    public var defaultTitle: String { "\(totalDays)-Tage-Fokus" }
    public var displayTitle: String {
        title.flatMap { $0.isEmpty ? nil : $0 } ?? defaultTitle
    }
}

/// Wie ein Lauf ausgegangen ist — oder gerade steht.
public enum FocusOutcome: Hashable, Sendable {
    /// Beginnt erst noch.
    case upcoming
    /// Läuft und ist bislang lückenlos.
    case running(dayNumber: Int, totalDays: Int)
    /// Bis zum letzten Tag durchgehalten.
    case completed
    /// An diesem Tag ist eine Lücke geblieben.
    case failed(on: CalendarDate)
    /// Vom Nutzer selbst beendet.
    case abandoned(on: CalendarDate)

    /// Ob der Lauf noch offen ist.
    public var isOpen: Bool {
        switch self {
        case .upcoming, .running: true
        case .completed, .failed, .abandoned: false
        }
    }

    public var isSuccess: Bool {
        if case .completed = self { true } else { false }
    }

    /// Stabiler String für Serialisierung und die spätere TypeScript-Portierung.
    public var code: String {
        switch self {
        case .upcoming: "upcoming"
        case .running: "running"
        case .completed: "completed"
        case .failed: "failed"
        case .abandoned: "abandoned"
        }
    }
}

/// Ein ausgewerteter Lauf.
public struct FocusProgress: Hashable, Sendable {
    public let run: FocusRun
    public let outcome: FocusOutcome
    /// Je Tag des Fensters, auch für Tage in der Zukunft.
    public let days: [CalendarDate: DaySummary]
    /// Tage, an denen alles Anstehende erledigt war.
    public let perfectDays: Int
    /// Tage des Fensters, an denen überhaupt etwas anstand.
    ///
    /// Der ehrliche Nenner. Ein Fokus über einen Mo/Mi/Fr-Habit hat in sieben
    /// Tagen nur drei zu vergebende — „3 von 7“ neben „durchgezogen“ zu zeigen
    /// widerspräche sich selbst.
    public let plannedDays: Int
    /// Bereits vergangene Tage des Fensters, heute eingeschlossen.
    public let elapsedDays: Int

    public var totalDays: Int { run.totalDays }

    /// Fortschritt 0…1 für den Ring in der Oberfläche.
    ///
    /// Ein Fenster ohne einen einzigen geplanten Tag ist vollständig, nicht leer.
    public var fraction: Double {
        plannedDays > 0 ? Double(perfectDays) / Double(plannedDays) : 1
    }
}

/// Wertet einen Lauf gegen die Einträge aus.
///
/// Die Regel ist bewusst dieselbe wie in der Übersicht: ein Tag ist geschafft,
/// wenn alles erledigt ist, was an ihm *verpflichtend* war. Damit gilt auch hier,
/// dass ein `timesPerWeek`-Habit einen einzelnen Tag nicht reißen kann und dass
/// Urlaub den Tag herausnimmt — während ein Streak Freeze ihn *nicht* rettet:
/// ein Fokus ist das strengere Versprechen.
///
/// Ein Tag ohne Plan bricht nichts. Der laufende Tag ebenfalls nicht, solange
/// er noch offen ist — sonst stünde jeder Fokus jeden Morgen als gescheitert da.
public func evaluate(
    _ run: FocusRun,
    habits: [Habit],
    entries: [Entry],
    exceptions: [DayException] = [],
    today: CalendarDate
) -> FocusProgress {
    let participating = habits.filter { run.includes(habitId: $0.id) }
    let summaries = overview(habits: participating, entries: entries,
                             exceptions: exceptions,
                             from: run.startsOn, to: run.endsOn, today: today)

    let window = run.startsOn.through(run.endsOn)
    let perfectDays = window.filter { summaries[$0]?.isPerfect ?? false }.count
    let plannedDays = window.filter { ($0 <= today) && (summaries[$0]?.scheduled ?? 0) > 0 }.count
    let elapsed = today < run.startsOn
        ? 0
        : min(run.totalDays, run.startsOn.days(until: today) + 1)

    func progress(_ outcome: FocusOutcome) -> FocusProgress {
        FocusProgress(run: run, outcome: outcome, days: summaries,
                      perfectDays: perfectDays, plannedDays: plannedDays,
                      elapsedDays: elapsed)
    }

    // Selbst beendet schlägt alles andere — auch einen Lauf, der rechnerisch
    // noch zu retten wäre.
    if let abandonedOn = run.abandonedOn {
        return progress(.abandoned(on: abandonedOn))
    }
    if today < run.startsOn {
        return progress(.upcoming)
    }

    // Der erste vergangene Tag mit einer Lücke entscheidet.
    for date in window where date < today {
        if let summary = summaries[date], summary.scheduled > 0, !summary.isPerfect {
            return progress(.failed(on: date))
        }
    }

    if run.endsOn < today {
        return progress(.completed)
    }
    // Letzter Tag und heute schon vollständig: das Ergebnis steht, ohne dass
    // man bis Mitternacht warten muss.
    if run.endsOn == today, let summary = summaries[today],
       summary.scheduled == 0 || summary.isPerfect {
        return progress(.completed)
    }
    return progress(.running(dayNumber: elapsed, totalDays: run.totalDays))
}

/// Bilanz über alle Läufe — die Kopfzeile des Fokus-Tabs.
public struct FocusRecord: Hashable, Sendable {
    public let completed: Int
    public let failed: Int
    public let abandoned: Int
    /// Längste Kette unmittelbar aufeinander folgender geschaffter Läufe.
    public let longestWinStreak: Int

    public var finished: Int { completed + failed + abandoned }
    /// Anteil geschaffter an abgeschlossenen Läufen, `nil` ohne abgeschlossenen.
    public var successRate: Double? {
        finished == 0 ? nil : Double(completed) / Double(finished)
    }
}

/// Bilanziert abgeschlossene Läufe. Laufende und künftige bleiben draußen —
/// ein noch offener Lauf ist weder Erfolg noch Misserfolg.
public func record(of outcomes: [FocusOutcome]) -> FocusRecord {
    var completed = 0, failed = 0, abandoned = 0
    var streak = 0, longest = 0

    for outcome in outcomes {
        switch outcome {
        case .completed:
            completed += 1
            streak += 1
            longest = max(longest, streak)
        case .failed:
            failed += 1
            streak = 0
        case .abandoned:
            abandoned += 1
            streak = 0
        case .upcoming, .running:
            continue          // unterbricht die Kette nicht, zählt aber nicht mit
        }
    }

    return FocusRecord(completed: completed, failed: failed,
                       abandoned: abandoned, longestWinStreak: longest)
}
