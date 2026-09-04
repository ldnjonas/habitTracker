import Foundation

public enum HabitKind: String, Codable, CaseIterable, Sendable, Hashable {
    /// Erledigt oder nicht.
    case binary
    /// Menge gegen ein Ziel.
    case quantity
    /// Vermeidung — gemeldet werden nur Verstöße.
    case avoid
}

/// Woher ein Eintrag stammt. Wichtig, damit ein späterer HealthKit-Abgleich
/// niemals eine manuelle Korrektur überschreibt.
public enum EntrySource: String, Codable, CaseIterable, Sendable, Hashable {
    case manual, healthKit, shortcut, api, importedFile
}

/// Verknüpfung zu Apple Health. In v1 nur im Modell, noch ohne Auswertung.
public struct HealthKitLink: Codable, Hashable, Sendable {
    public var typeIdentifier: String     // z. B. "HKQuantityTypeIdentifierStepCount"
    public var unit: String               // z. B. "count"
    public var aggregation: String        // "sum" | "max" | "latest"

    public init(typeIdentifier: String, unit: String, aggregation: String) {
        self.typeIdentifier = typeIdentifier
        self.unit = unit
        self.aggregation = aggregation
    }
}

public struct Habit: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var userId: String
    public var name: String
    public var notes: String?
    public var kind: HabitKind
    /// Nach `effectiveFrom` aufsteigend sortiert; siehe `rule(on:)`.
    public var rules: [HabitRule]
    public var colorHex: String
    public var symbol: String
    public var sortOrder: Int
    public var tagIds: [UUID]
    public var timeOfDay: TimeOfDay?
    public var preferredTime: String?     // "07:30"
    public var tracksTime: Bool
    public var startsOn: CalendarDate?
    public var endsOn: CalendarDate?
    public var healthKitLink: HealthKitLink?
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    /// Archiviert ist nicht gelöscht: der Habit verschwindet aus „Heute",
    /// bleibt aber in Verlauf und Statistik erhalten.
    ///
    /// Bewusst ein Kalendertag und kein Zeitstempel — die Domäne muss ab welchem
    /// *Tag* nicht mehr geplant wird auswerten können, ohne eine Zeitzone zu kennen.
    public var archivedOn: CalendarDate?

    public init(
        id: UUID = UUID(),
        userId: String = Habit.localUserId,
        name: String,
        notes: String? = nil,
        kind: HabitKind = .binary,
        rules: [HabitRule],
        colorHex: String = "#4F8DF7",
        symbol: String = "checkmark.circle",
        sortOrder: Int = 0,
        tagIds: [UUID] = [],
        timeOfDay: TimeOfDay? = nil,
        preferredTime: String? = nil,
        tracksTime: Bool = false,
        startsOn: CalendarDate? = nil,
        endsOn: CalendarDate? = nil,
        healthKitLink: HealthKitLink? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil,
        archivedOn: CalendarDate? = nil
    ) {
        self.id = id
        self.userId = userId
        self.name = name
        self.notes = notes
        self.kind = kind
        self.rules = rules.sorted { $0.effectiveFrom < $1.effectiveFrom }
        self.colorHex = colorHex
        self.symbol = symbol
        self.sortOrder = sortOrder
        self.tagIds = tagIds
        self.timeOfDay = timeOfDay
        self.preferredTime = preferredTime
        self.tracksTime = tracksTime
        self.startsOn = startsOn
        self.endsOn = endsOn
        self.healthKitLink = healthKitLink
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.archivedOn = archivedOn
    }

    /// Platzhalter, solange die App ohne Server läuft. Steht ab Tag 1 in jeder
    /// Zeile, damit der spätere Login keine Datenmigration braucht.
    public static let localUserId = "local"

    public var isArchived: Bool { archivedOn != nil }
    public var isChallenge: Bool { startsOn != nil && endsOn != nil }
}

public struct Tag: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var userId: String
    public var name: String
    public var colorHex: String
    public var sortOrder: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(
        id: UUID = UUID(),
        userId: String = Habit.localUserId,
        name: String,
        colorHex: String = "#8E8E93",
        sortOrder: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.userId = userId
        self.name = name
        self.colorHex = colorHex
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}
