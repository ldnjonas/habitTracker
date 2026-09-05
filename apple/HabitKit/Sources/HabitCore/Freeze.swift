import Foundation

/// Wofür eine Buchung im Freeze-Konto steht.
public enum FreezeReason: String, Codable, Sendable, Hashable, CaseIterable {
    /// Ein Fokus-Lauf wurde durchgezogen.
    case focusCompleted
    /// Ein Freeze wurde für einen Tag eingelöst.
    case applied
    /// Startguthaben oder von Hand vergeben.
    case granted
}

/// Eine einzelne Buchung.
///
/// Bewusst ein Ledger und kein Zähler: der Kontostand ist die Summe, nie ein
/// gespeicherter Wert. Ein Zähler kann falsch werden, ohne dass man sieht wie —
/// eine Buchungsreihe nicht, und beim Sync bleibt sie konfliktfrei, weil nur
/// angehängt wird. Deshalb hat die Tabelle auch kein `updated_at` und keinen
/// Grabstein: Buchungen werden nicht geändert und nicht gelöscht.
public struct FreezeEntry: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var userId: String
    /// Positiv verdient, negativ eingelöst.
    public var amount: Int
    public var reason: FreezeReason
    /// Bei einer Einlösung: der gerettete Habit.
    public var habitId: UUID?
    /// Bei einer Einlösung: der gerettete Tag.
    public var date: CalendarDate?
    /// Bei `focusCompleted`: der Lauf, der eingezahlt hat.
    ///
    /// Ohne diesen Bezug ließe sich nicht sagen, ob ein Lauf schon eingezahlt
    /// hat — und da `evaluate` sein Ergebnis bei jedem Aufruf neu ausrechnet,
    /// zahlte derselbe Lauf sonst bei jedem Nachladen erneut ein.
    public var focusRunId: UUID?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        userId: String = Habit.localUserId,
        amount: Int,
        reason: FreezeReason,
        habitId: UUID? = nil,
        date: CalendarDate? = nil,
        focusRunId: UUID? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.userId = userId
        self.amount = amount
        self.reason = reason
        self.habitId = habitId
        self.date = date
        self.focusRunId = focusRunId
        self.createdAt = createdAt
    }
}

/// Die Regeln des Guthabens.
public enum FreezeRule {
    /// Was ein durchgezogener Fokus einbringt.
    public static let perCompletedFocus = 1

    /// Obergrenze des Guthabens.
    ///
    /// Ohne sie sammelt man über Monate ein Polster an, das jeden Streak
    /// beliebig lange am Leben hält — dann sagt er nichts mehr aus. Drei
    /// reichen für eine Krankheitswoche und nicht für ein halbes Jahr Nachlässigkeit.
    public static let maximum = 3
}

/// Der Kontostand: die Summe aller Buchungen.
public func freezeBalance(_ ledger: [FreezeEntry]) -> Int {
    ledger.reduce(0) { $0 + $1.amount }
}

/// Welche durchgezogenen Läufe noch nicht eingezahlt haben.
///
/// Rein und ohne Datenbank, damit die Regel testbar ist und die spätere
/// TypeScript-Fassung dieselbe trifft. Die Obergrenze wird dabei laufend
/// mitgeführt: steht das Konto voll, verfällt der Anspruch — er wird nicht
/// aufgespart und später nachgezahlt, sonst wäre die Grenze wirkungslos.
public func pendingFreezeAwards(
    outcomes: [(run: FocusRun, outcome: FocusOutcome)],
    ledger: [FreezeEntry]
) -> [FocusRun] {
    let schonGebucht = Set(ledger.compactMap(\.focusRunId))
    var stand = freezeBalance(ledger)
    var faellig: [FocusRun] = []

    // Älteste zuerst: wer früher durchgezogen hat, bekommt bei knapper
    // Obergrenze auch zuerst.
    let kandidaten = outcomes
        .filter { $0.outcome.isSuccess && !schonGebucht.contains($0.run.id) }
        .sorted { $0.run.endsOn < $1.run.endsOn }

    for kandidat in kandidaten {
        guard stand < FreezeRule.maximum else { break }
        faellig.append(kandidat.run)
        stand += FreezeRule.perCompletedFocus
    }
    return faellig
}

/// Ob ein Tag sich überhaupt einfrieren lässt.
///
/// Nur ein bereits verpasster Tag: einen erfüllten braucht man nicht zu retten,
/// und der laufende ist noch nicht verloren. Ein Freeze auf die Zukunft wäre
/// eine Vorabentschuldigung — genau das, was der Streak nicht aussagen soll.
public func canFreeze(_ status: DayStatus, on date: CalendarDate, today: CalendarDate) -> Bool {
    guard date < today else { return false }
    if case .missed = status { return true }
    return false
}
