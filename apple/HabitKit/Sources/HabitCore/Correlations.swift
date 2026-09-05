import Foundation

/// Eine Größe aus dem Tages-Journal.
public enum JournalMetric: String, CaseIterable, Codable, Sendable, Hashable {
    case mood, energy, sleepHours

    /// Der Wert dieses Tages, falls erfasst.
    public func value(in log: DayLog) -> Double? {
        switch self {
        case .mood: log.mood.map(Double.init)
        case .energy: log.energy.map(Double.init)
        case .sleepHours: log.sleepHours
        }
    }
}

/// Wie deutlich ein Zusammenhang ist.
public enum CorrelationStrength: String, Codable, Sendable, Hashable {
    case weak, moderate, strong

    /// Übliche Schwellen auf dem Betrag von `r`. Unter 0,2 wird gar nichts
    /// berichtet — siehe `correlations(…)`.
    public init?(coefficient: Double) {
        switch abs(coefficient) {
        case ..<0.2: return nil
        case ..<0.4: self = .weak
        case ..<0.6: self = .moderate
        default: self = .strong
        }
    }
}

/// Ein gefundener Zusammenhang zwischen einem Habit und einer Journal-Größe.
///
/// Existiert nur, wenn er die Hürden aus `CorrelationRule` genommen hat — es
/// gibt keinen „schwachen“ oder „unsicheren“ Fall, den die Oberfläche noch
/// aussortieren müsste. Was hier ankommt, darf gezeigt werden.
public struct Correlation: Hashable, Sendable {
    public let habitId: UUID
    public let metric: JournalMetric
    /// Pearson, −1 bis 1.
    public let coefficient: Double
    public let strength: CorrelationStrength
    /// Tage, an denen sowohl der Habit entschieden als auch die Größe erfasst war.
    public let dayCount: Int
    public let completedDays: Int
    public let completedAverage: Double
    public let missedAverage: Double

    /// Um wie viel die Größe an erledigten Tagen höher liegt. Negativ heißt
    /// niedriger.
    public var difference: Double { completedAverage - missedAverage }
}

/// Die Hürden, ab denen eine Aussage überhaupt gemacht wird.
public enum CorrelationRule {
    /// Gemeinsame Datenpunkte insgesamt.
    public static let minimumDays = 14
    /// Und in **jeder** der beiden Gruppen.
    ///
    /// Ohne diese zweite Hürde stünde hinter „an Tagen ohne Sport“ womöglich ein
    /// einziger Tag — ein Mittelwert aus einem Wert ist kein Mittelwert.
    public static let minimumPerGroup = 5
    /// Untergrenze aus Sachgründen, unabhängig von der Datenmenge.
    ///
    /// Bei sehr vielen Tagen wird auch ein Zusammenhang von 0,15 rechnerisch
    /// bedeutsam — der Sache nach ist er es nicht.
    public static let minimumCoefficient = 0.2

    /// Die Zufallshürde, ausgedrückt als t-Wert.
    ///
    /// Eine feste Schwelle auf `r` genügt nicht: bei 30 Tagen liegt die
    /// Zufallsgrenze bei rund 0,36, bei 100 Tagen bei 0,26. Wer fest bei 0,2
    /// abschneidet, meldet bei kleinen Mengen reines Rauschen als Befund — in
    /// der Erprobung erschienen so sechs „Zusammenhänge“, darunter einer mit
    /// einer Größe, die ich als Zufallszahl erzeugt hatte.
    ///
    /// 3,0 entspricht etwa p < 0,01 (zweiseitig) und ist damit strenger als
    /// üblich. Das ist Absicht: über acht Habits und drei Größen werden zwei
    /// Dutzend Paare gleichzeitig geprüft, und bei p < 0,05 wäre gut ein
    /// Fehltreffer schon rechnerisch zu erwarten.
    public static let criticalT = 3.0

    /// Der nötige Betrag von `r` bei dieser Zahl gemeinsamer Tage.
    ///
    /// Aus `t = r · √(df / (1 − r²))` nach `r` aufgelöst.
    public static func requiredCoefficient(forDays days: Int) -> Double {
        let df = Double(days - 2)
        guard df > 0 else { return 1 }
        let t = criticalT
        return max(minimumCoefficient, t / (df + t * t).squareRoot())
    }
}

/// Sucht Zusammenhänge zwischen Habits und dem Journal.
///
/// **Die Zurückhaltung ist Teil der Funktion.** Bei wenigen Tagen findet man in
/// Zufallsrauschen immer irgendeinen Zusammenhang; wird er angezeigt, glaubt man
/// ihn. Deshalb drei Hürden: mindestens `minimumDays` gemeinsame Tage,
/// mindestens `minimumPerGroup` in jeder Gruppe, und ein Betrag über der
/// Zufallsgrenze für *diese* Datenmenge — nicht über einer festen Zahl. Wird
/// eine Hürde gerissen, kommt kein abgeschwächtes Ergebnis, sondern keins.
///
/// Und es bleibt bei „hängt zusammen“: dass Sport den Schlaf verbessert, sagen
/// diese Daten nicht — vielleicht schläft man an Tagen besser, an denen ohnehin
/// alles leichter fällt.
public func correlations(
    habits: [Habit],
    entries: [Entry],
    dayLogs: [DayLog],
    exceptions: [DayException] = [],
    from: CalendarDate,
    to: CalendarDate,
    today: CalendarDate
) -> [Correlation] {
    let logsByDay = Dictionary(dayLogs.filter { $0.deletedAt == nil }.map { ($0.date, $0) },
                               uniquingKeysWith: { first, _ in first })
    guard !logsByDay.isEmpty else { return [] }

    var result: [Correlation] = []

    for habit in habits {
        let statuses = dayStatuses(for: habit, entries: entries, exceptions: exceptions,
                                   from: from, to: to, today: today)

        for metric in JournalMetric.allCases {
            // Nur Tage, an denen beides feststeht: der Habit entschieden
            // (erledigt oder verpasst) und die Größe erfasst.
            var erledigt: [Double] = []
            var verpasst: [Double] = []
            for (date, status) in statuses {
                guard let log = logsByDay[date], let wert = metric.value(in: log) else { continue }
                switch status {
                case .completed: erledigt.append(wert)
                case .missed: verpasst.append(wert)
                default: continue
                }
            }

            let tage = erledigt.count + verpasst.count
            guard tage >= CorrelationRule.minimumDays,
                  erledigt.count >= CorrelationRule.minimumPerGroup,
                  verpasst.count >= CorrelationRule.minimumPerGroup,
                  let r = pearson(erledigt: erledigt, verpasst: verpasst),
                  // Die Hürde sinkt mit wachsender Datenmenge — bei 30 Tagen
                  // braucht es 0,49, bei 100 nur noch 0,29.
                  abs(r) >= CorrelationRule.requiredCoefficient(forDays: tage),
                  let staerke = CorrelationStrength(coefficient: r)
            else { continue }

            result.append(Correlation(
                habitId: habit.id, metric: metric, coefficient: r, strength: staerke,
                dayCount: erledigt.count + verpasst.count,
                completedDays: erledigt.count,
                completedAverage: erledigt.reduce(0, +) / Double(erledigt.count),
                missedAverage: verpasst.reduce(0, +) / Double(verpasst.count)))
        }
    }

    // Der deutlichste zuerst.
    return result.sorted { abs($0.coefficient) > abs($1.coefficient) }
}

/// Pearson zwischen einer Ja/Nein-Größe (erledigt) und einer Zahl.
///
/// `nil`, wenn die Journal-Werte keine Streuung haben — wer jeden Tag „3“
/// einträgt, hat keinen Zusammenhang, sondern eine Gewohnheit beim Eintragen.
func pearson(erledigt: [Double], verpasst: [Double]) -> Double? {
    let x = Array(repeating: 1.0, count: erledigt.count)
        + Array(repeating: 0.0, count: verpasst.count)
    let y = erledigt + verpasst
    let n = Double(x.count)
    guard n > 1 else { return nil }

    let xMittel = x.reduce(0, +) / n
    let yMittel = y.reduce(0, +) / n
    var zaehler = 0.0, xQuadrat = 0.0, yQuadrat = 0.0
    for i in x.indices {
        let dx = x[i] - xMittel, dy = y[i] - yMittel
        zaehler += dx * dy
        xQuadrat += dx * dx
        yQuadrat += dy * dy
    }
    guard xQuadrat > 0, yQuadrat > 0 else { return nil }
    return zaehler / (xQuadrat * yQuadrat).squareRoot()
}

/// Der Tagesstatus eines Habits über einen Zeitraum.
///
/// Eigene kleine Hilfsfunktion statt `stats(…)`, weil hier nur die Tage
/// gebraucht werden und nicht Streaks, Quote und Wochentagsverteilung dazu.
func dayStatuses(
    for habit: Habit,
    entries: [Entry],
    exceptions: [DayException],
    from: CalendarDate,
    to: CalendarDate,
    today: CalendarDate
) -> [CalendarDate: DayStatus] {
    var entriesByDay: [CalendarDate: Entry] = [:]
    for entry in entries where entry.deletedAt == nil && entry.habitId == habit.id {
        entriesByDay[entry.date] = entry
    }
    var perHabit: [CalendarDate: DayException] = [:]
    var global: [CalendarDate: DayException] = [:]
    for exception in exceptions where exception.deletedAt == nil {
        if exception.habitId == habit.id { perHabit[exception.date] = exception }
        else if exception.habitId == nil { global[exception.date] = exception }
    }

    var result: [CalendarDate: DayStatus] = [:]
    for date in from.through(to) {
        result[date] = status(for: habit, entry: entriesByDay[date],
                              exception: perHabit[date] ?? global[date],
                              on: date, today: today)
    }
    return result
}
