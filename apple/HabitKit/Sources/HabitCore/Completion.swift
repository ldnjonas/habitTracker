/// Bewertet einen einzelnen Tag.
///
/// Die Reihenfolge der Prüfungen ist bedeutungstragend:
/// Zukunft schlägt Ausnahme, Ausnahme schlägt Zeitplan, Erfüllung schlägt Freeze.
public func status(
    for habit: Habit,
    entry: Entry?,
    exception: DayException?,
    on date: CalendarDate,
    today: CalendarDate
) -> DayStatus {
    if date > today { return .future }

    // Urlaub und Ruhetage nehmen den Tag komplett aus dem Zeitplan — auch dann,
    // wenn er sonst gar nicht geplant gewesen wäre. Das hält die Anzeige ehrlich.
    if let exception, exception.kind.removesDayFromSchedule {
        return .excepted(exception.kind)
    }

    guard habit.isScheduled(on: date) else { return .notScheduled }

    let value = entry?.value ?? 0
    if habit.isFulfilled(value: value, on: date) { return .completed }

    // Der laufende Tag ist noch nicht verloren.
    if date == today { return .partial(habit.progress(value: value, on: date)) }

    if let exception, exception.kind == .frozen { return .excepted(.frozen) }

    // Bei `timesPerWeek` ist ein leerer Tag kein Versäumnis, sondern nur ein Tag,
    // an dem nichts passiert ist — bewertet wird dort die Woche.
    return habit.isRequired(on: date) ? .missed : .notScheduled
}
