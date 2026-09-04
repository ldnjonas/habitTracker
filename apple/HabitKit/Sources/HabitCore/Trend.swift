/// Kurzfristige Entwicklung eines Habits.
public enum Trend: Sendable, Hashable {
    /// Deutlich besser als im Vergleichszeitraum; der Wert ist die Differenz
    /// in Prozentpunkten (0...1).
    case improving(Double)
    case stable
    /// Deutlich schlechter — das ist der Moment, in dem Eingreifen noch hilft.
    case declining(Double)

    public var code: String {
        switch self {
        case .improving: "improving"
        case .stable: "stable"
        case .declining: "declining"
        }
    }
}

/// Ab wie vielen Prozentpunkten Unterschied eine Richtung behauptet wird.
public let trendThreshold = 0.15
/// Wie viele bewertete Einheiten je Seite mindestens vorliegen müssen.
public let trendMinimumSamples = 5

/// Vergleicht die letzten `window` Tage mit den `window` davor.
///
/// Der heutige Tag bleibt außen vor: er ist noch nicht vorbei und würde den
/// aktuellen Zeitraum systematisch nach unten ziehen.
///
/// Gibt `nil` zurück, wenn die Datenbasis auf einer der beiden Seiten zu dünn
/// ist — lieber keine Aussage als eine aus drei Tagen abgeleitete.
public func trend(
    for habit: Habit,
    entries: [Entry],
    exceptions: [DayException] = [],
    today: CalendarDate,
    window: Int = 14
) -> Trend? {
    let recentEnd = today.adding(days: -1)
    let recentStart = recentEnd.adding(days: -(window - 1))
    let priorEnd = recentStart.adding(days: -1)
    let priorStart = priorEnd.adding(days: -(window - 1))

    let recent = stats(for: habit, entries: entries, exceptions: exceptions,
                       from: recentStart, to: recentEnd, today: today)
    let prior = stats(for: habit, entries: entries, exceptions: exceptions,
                      from: priorStart, to: priorEnd, today: today)

    guard recent.evaluatedCount >= trendMinimumSamples,
          prior.evaluatedCount >= trendMinimumSamples,
          let recentRate = recent.completionRate,
          let priorRate = prior.completionRate
    else { return nil }

    let delta = recentRate - priorRate
    if delta > trendThreshold { return .improving(delta) }
    if delta < -trendThreshold { return .declining(-delta) }
    return .stable
}
