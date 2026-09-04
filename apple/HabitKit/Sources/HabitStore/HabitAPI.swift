import Foundation
import HabitCore

/// Die Schnittstelle, die alle Clients sehen.
///
/// Die Methoden bilden 1:1 die Endpunkte aus `spec/openapi.yaml` ab. Auf Mac und
/// iPhone steht dahinter dauerhaft `LocalHabitAPI` mit lokaler SQLite-Datenbank —
/// nicht als Platzhalter, sondern weil ein Telefon offline benutzbar bleiben
/// muss. Nur die WebApp wird einen rein entfernten Client gegen dieselbe Form
/// bekommen.
public protocol HabitAPI: Sendable {
    // Habits
    func listHabits(includeArchived: Bool) async throws -> [Habit]
    func habit(id: UUID) async throws -> Habit?
    func createHabit(_ draft: HabitDraft) async throws -> Habit
    func updateHabit(id: UUID, _ patch: HabitPatch) async throws -> Habit
    func deleteHabit(id: UUID) async throws
    func setRule(habitId: UUID, _ rule: HabitRule) async throws -> Habit
    func deleteRule(habitId: UUID, effectiveFrom: CalendarDate) async throws -> Habit

    // Tags
    func tags() async throws -> [Tag]
    func createTag(name: String, colorHex: String) async throws -> Tag
    func updateTag(_ tag: Tag) async throws -> Tag
    func deleteTag(id: UUID) async throws
    func setTags(habitId: UUID, tagIds: [UUID]) async throws -> Habit

    // Einträge
    func entries(habitId: UUID?, from: CalendarDate, to: CalendarDate) async throws -> [Entry]
    @discardableResult
    func setEntry(habitId: UUID, date: CalendarDate, value: Double,
                  note: String?, source: EntrySource) async throws -> Entry
    func deleteEntry(habitId: UUID, date: CalendarDate) async throws

    // Zeitstempel-Detail
    func events(habitId: UUID, from: CalendarDate, to: CalendarDate) async throws -> [EntryEvent]
    @discardableResult
    func setEvent(_ event: EntryEvent) async throws -> EntryEvent
    func deleteEvent(habitId: UUID, eventId: UUID) async throws

    // Journal und Ausnahmen
    func dayLogs(from: CalendarDate, to: CalendarDate) async throws -> [DayLog]
    @discardableResult
    func setDayLog(_ log: DayLog) async throws -> DayLog
    func exceptions(from: CalendarDate, to: CalendarDate) async throws -> [DayException]
    @discardableResult
    func addException(_ exception: DayException) async throws -> DayException
    func deleteException(id: UUID) async throws

    // Papierkorb
    func trash() async throws -> [TrashItem]
    func restore(_ item: TrashItem) async throws

    // Auswertung
    func stats(habitId: UUID, from: CalendarDate, to: CalendarDate) async throws -> HabitStats
    func trend(habitId: UUID) async throws -> Trend?

    // Einstellungen
    func backfillLimitDays() async throws -> Int
    func setBackfillLimitDays(_ days: Int) async throws
}

/// Was zum Anlegen eines Habits nötig ist. Alles Weitere hat Vorgaben.
public struct HabitDraft: Sendable {
    public var name: String
    public var kind: HabitKind
    public var rules: [HabitRule]
    public var notes: String?
    public var colorHex: String
    public var symbol: String
    public var tagIds: [UUID]
    public var timeOfDay: TimeOfDay?
    public var preferredTime: String?
    public var tracksTime: Bool
    public var startsOn: CalendarDate?
    public var endsOn: CalendarDate?

    public init(
        name: String,
        kind: HabitKind = .binary,
        rules: [HabitRule],
        notes: String? = nil,
        colorHex: String = "#4F8DF7",
        symbol: String = "checkmark.circle",
        tagIds: [UUID] = [],
        timeOfDay: TimeOfDay? = nil,
        preferredTime: String? = nil,
        tracksTime: Bool = false,
        startsOn: CalendarDate? = nil,
        endsOn: CalendarDate? = nil
    ) {
        self.name = name
        self.kind = kind
        self.rules = rules
        self.notes = notes
        self.colorHex = colorHex
        self.symbol = symbol
        self.tagIds = tagIds
        self.timeOfDay = timeOfDay
        self.preferredTime = preferredTime
        self.tracksTime = tracksTime
        self.startsOn = startsOn
        self.endsOn = endsOn
    }
}

/// Teiländerung eines Habits.
///
/// Doppelt optional, wo ein Feld auf `nil` gesetzt werden können muss:
/// `nil` heißt „nicht anfassen", `.some(nil)` heißt „leeren".
/// Zeitplan und Ziel fehlen bewusst — die laufen über `setRule`.
public struct HabitPatch: Sendable {
    public var name: String?
    public var notes: String??
    public var colorHex: String?
    public var symbol: String?
    public var sortOrder: Int?
    public var timeOfDay: TimeOfDay??
    public var preferredTime: String??
    public var tracksTime: Bool?
    public var startsOn: CalendarDate??
    public var endsOn: CalendarDate??
    public var archivedOn: CalendarDate??
    public var healthKitLink: HealthKitLink??

    public init(
        name: String? = nil,
        notes: String?? = nil,
        colorHex: String? = nil,
        symbol: String? = nil,
        sortOrder: Int? = nil,
        timeOfDay: TimeOfDay?? = nil,
        preferredTime: String?? = nil,
        tracksTime: Bool? = nil,
        startsOn: CalendarDate?? = nil,
        endsOn: CalendarDate?? = nil,
        archivedOn: CalendarDate?? = nil,
        healthKitLink: HealthKitLink?? = nil
    ) {
        self.name = name
        self.notes = notes
        self.colorHex = colorHex
        self.symbol = symbol
        self.sortOrder = sortOrder
        self.timeOfDay = timeOfDay
        self.preferredTime = preferredTime
        self.tracksTime = tracksTime
        self.startsOn = startsOn
        self.endsOn = endsOn
        self.archivedOn = archivedOn
        self.healthKitLink = healthKitLink
    }
}

/// Ein wiederherstellbarer Eintrag im Papierkorb.
public struct TrashItem: Codable, Hashable, Sendable, Identifiable {
    public enum Table: String, Codable, Sendable, CaseIterable {
        case habit, entry, entryEvent = "entry_event"
        case dayException = "day_exception", dayLog = "day_log", tag
    }

    public var table: Table
    /// Bei Tabellen mit zusammengesetztem Schlüssel der zusammengefügte Wert.
    public var rowId: String
    public var deletedAt: Date
    public var label: String

    public var id: String { "\(table.rawValue):\(rowId)" }

    public init(table: Table, rowId: String, deletedAt: Date, label: String) {
        self.table = table
        self.rowId = rowId
        self.deletedAt = deletedAt
        self.label = label
    }
}

public enum HabitStoreError: Error, Equatable, CustomStringConvertible {
    case habitNotFound(UUID)
    case tagNotFound(UUID)
    case ruleNotFound(habitId: UUID, effectiveFrom: CalendarDate)
    case needsAtLeastOneRule
    /// Der Eintrag liegt weiter zurück, als `backfillLimitDays` erlaubt.
    case backfillLimitExceeded(date: CalendarDate, limitDays: Int)

    public var description: String {
        switch self {
        case .habitNotFound(let id): "Habit \(id) nicht gefunden"
        case .tagNotFound(let id): "Tag \(id) nicht gefunden"
        case .ruleNotFound(let habitId, let from): "Regel ab \(from) für \(habitId) nicht gefunden"
        case .needsAtLeastOneRule: "Ein Habit braucht mindestens eine Regel"
        case .backfillLimitExceeded(let date, let limit):
            "\(date) liegt weiter als \(limit) Tage zurück"
        }
    }
}
