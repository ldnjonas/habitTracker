/// Wie ein einzelner Tag für einen Habit ausgegangen ist.
public enum DayStatus: Hashable, Sendable {
    /// Ziel erreicht.
    case completed
    /// Heute, noch nicht fertig. Der zugehörige Wert ist der Fortschritt (0...1).
    /// Ein *vergangener* Tag ist nie `partial`, sondern `missed` — halb erledigt
    /// ist rückblickend nicht erledigt.
    case partial(Double)
    /// Geplanter Tag in der Vergangenheit ohne Erfüllung.
    case missed
    /// Ausnahme: eingefroren, pausiert oder bewusst übersprungen.
    case excepted(ExceptionKind)
    /// An diesem Tag war der Habit nicht fällig.
    case notScheduled
    /// Liegt in der Zukunft.
    case future

    /// Stabiler String für Fixtures, Serialisierung und die spätere
    /// TypeScript-Portierung.
    public var code: String {
        switch self {
        case .completed: "completed"
        case .partial: "partial"
        case .missed: "missed"
        case .excepted(let kind): kind.rawValue
        case .notScheduled: "notScheduled"
        case .future: "future"
        }
    }

    /// Zählt für Streak und Completion-Rate als Erfolg.
    public var isCompleted: Bool {
        if case .completed = self { true } else { false }
    }

    /// Ob dieser Tag im Nenner der Completion-Rate landet.
    ///
    /// Ein eingefrorener Tag zählt weiter als verpasst — ein Freeze rettet den
    /// Streak, schönt aber nicht die Statistik. Urlaub und Ruhetage fallen ganz
    /// heraus, weil sie nie vorgesehen waren.
    public var countsTowardRate: Bool {
        switch self {
        case .completed, .missed: true
        case .excepted(let kind): kind == .frozen
        // Der laufende Tag ist noch nicht entschieden. Zählte er mit, stünde die
        // Quote jeden Morgen schlechter da und erholte sich erst am Abend.
        case .partial: false
        case .notScheduled, .future: false
        }
    }
}

extension DayStatus: CustomStringConvertible {
    public var description: String { code }
}
