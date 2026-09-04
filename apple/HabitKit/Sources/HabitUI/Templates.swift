import Foundation
import HabitCore
import HabitStore

/// Ein Vorschlag für den ersten Start.
///
/// Bewusst eine Ressource im Package und keine Datenbanktabelle: Vorlagen
/// ändern sich nie zur Laufzeit und müssen nicht synchronisiert werden.
public struct HabitTemplate: Decodable, Identifiable, Sendable, Hashable {
    public var name: String
    public var symbol: String
    public var colorHex: String
    public var kind: HabitKind
    public var schedule: Schedule
    public var target: Target?
    public var timeOfDay: TimeOfDay?

    public var id: String { name }

    /// Baut daraus einen anlegbaren Entwurf mit Startdatum heute.
    public func draft(startingOn date: CalendarDate) -> HabitDraft {
        HabitDraft(
            name: name, kind: kind,
            rules: [HabitRule(effectiveFrom: date, schedule: schedule, target: target)],
            colorHex: colorHex, symbol: symbol, timeOfDay: timeOfDay
        )
    }

    /// Kurzbeschreibung für die Auswahlkachel: „Täglich · mindestens 2 L".
    public var subtitle: String {
        var parts = [schedule.label]
        if let target {
            let prefix = target.comparison == .atLeast ? "mindestens" : "höchstens"
            parts.append("\(prefix) \(number(target.value)) \(target.unit)")
        } else if kind == .avoid {
            parts.append("vermeiden")
        }
        return parts.joined(separator: " · ")
    }

    public static let all: [HabitTemplate] = {
        guard let url = Bundle.module.url(forResource: "templates", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([HabitTemplate].self, from: data)
        else {
            // Fehlende Vorlagen dürfen den ersten Start nicht blockieren —
            // dann eben ein leerer Bildschirm mit „Habit anlegen".
            return []
        }
        return list
    }()
}
