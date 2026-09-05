import Foundation
import GRDB
import HabitCore

/// Datensätze bilden Tabellenzeilen ab, die Domänentypen nicht.
///
/// Getrennt, weil ein `Habit` über drei Tabellen verteilt ist (Stammdaten,
/// Regeln, Tag-Zuordnung) und weil die Sync-Spalten in der Domäne nichts zu
/// suchen haben.
protocol SnakeCaseRecord: Codable, FetchableRecord, MutablePersistableRecord {}

extension SnakeCaseRecord {
    static var databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy {
        .convertFromSnakeCase
    }
    static var databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy {
        .convertToSnakeCase
    }
}

// MARK: - habit

struct HabitRow: SnakeCaseRecord {
    static let databaseTableName = "habit"

    var id: String
    var userId: String
    var name: String
    var notes: String?
    var kind: HabitKind
    var colorHex: String
    var symbol: String
    var sortOrder: Int
    var timeOfDay: TimeOfDay?
    var preferredTime: String?
    var tracksTime: Bool
    var startsOn: CalendarDate?
    var endsOn: CalendarDate?
    var archivedOn: CalendarDate?
    var healthKitLink: String?          // JSON
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?
    var serverSeq: Int64?
    var dirty: Bool

    init(_ habit: Habit) throws {
        id = habit.id.uuidString
        userId = habit.userId
        name = habit.name
        notes = habit.notes
        kind = habit.kind
        colorHex = habit.colorHex
        symbol = habit.symbol
        sortOrder = habit.sortOrder
        timeOfDay = habit.timeOfDay
        preferredTime = habit.preferredTime
        tracksTime = habit.tracksTime
        startsOn = habit.startsOn
        endsOn = habit.endsOn
        archivedOn = habit.archivedOn
        healthKitLink = try habit.healthKitLink.map(JSONColumn.encode)
        createdAt = habit.createdAt
        updatedAt = habit.updatedAt
        deletedAt = habit.deletedAt
        serverSeq = nil
        dirty = true
    }

    /// Setzt den Habit aus Stammdaten, Regeln und Tag-Zuordnung zusammen.
    func habit(rules: [HabitRule], tagIds: [UUID]) throws -> Habit {
        Habit(
            id: UUID(uuidString: id)!,
            userId: userId,
            name: name,
            notes: notes,
            kind: kind,
            rules: rules,
            colorHex: colorHex,
            symbol: symbol,
            sortOrder: sortOrder,
            tagIds: tagIds,
            timeOfDay: timeOfDay,
            preferredTime: preferredTime,
            tracksTime: tracksTime,
            startsOn: startsOn,
            endsOn: endsOn,
            healthKitLink: try healthKitLink.map { try JSONColumn.decode(HealthKitLink.self, from: $0) },
            createdAt: createdAt,
            updatedAt: updatedAt,
            deletedAt: deletedAt,
            archivedOn: archivedOn
        )
    }
}

// MARK: - habit_rule

struct HabitRuleRow: SnakeCaseRecord {
    static let databaseTableName = "habit_rule"

    var habitId: String
    var effectiveFrom: CalendarDate
    /// Redundant zur Nutzlast, aber als eigene Spalte abfragbar — praktisch für
    /// „alle Habits mit Wochenziel" ohne JSON zu parsen.
    var scheduleKind: String
    var schedulePayload: String         // JSON
    var targetValue: Double?
    var targetUnit: String?
    var targetComparison: Comparison?
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?
    /// Die `id` der Zeile, mit der diese zusammen gelöscht wurde — `nil` bei
    /// eigenständiger Löschung. Nur aussagekräftig, solange `deletedAt` steht.
    var deletedWith: String?
    var serverSeq: Int64?
    var dirty: Bool

    init(habitId: UUID, rule: HabitRule, now: Date = Date()) throws {
        self.habitId = habitId.uuidString
        effectiveFrom = rule.effectiveFrom
        scheduleKind = HabitRuleRow.kindName(rule.schedule)
        schedulePayload = try JSONColumn.encode(rule.schedule)
        targetValue = rule.target?.value
        targetUnit = rule.target?.unit
        targetComparison = rule.target?.comparison
        createdAt = now
        updatedAt = now
        deletedAt = nil
        deletedWith = nil
        serverSeq = nil
        dirty = true
    }

    var rule: HabitRule {
        get throws {
            let schedule = try JSONColumn.decode(Schedule.self, from: schedulePayload)
            let target: Target? = if let targetValue, let targetUnit {
                Target(value: targetValue, unit: targetUnit,
                       comparison: targetComparison ?? .atLeast)
            } else { nil }
            return HabitRule(effectiveFrom: effectiveFrom, schedule: schedule, target: target)
        }
    }

    static func kindName(_ schedule: Schedule) -> String {
        switch schedule {
        case .daily: "daily"
        case .weekdays: "weekdays"
        case .timesPerWeek: "timesPerWeek"
        case .everyNDays: "everyNDays"
        }
    }
}

// MARK: - tag

struct TagRow: SnakeCaseRecord {
    static let databaseTableName = "tag"

    var id: String
    var userId: String
    var name: String
    var colorHex: String
    var sortOrder: Int
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?
    var serverSeq: Int64?
    var dirty: Bool

    init(_ tag: Tag) {
        id = tag.id.uuidString
        userId = tag.userId
        name = tag.name
        colorHex = tag.colorHex
        sortOrder = tag.sortOrder
        createdAt = tag.createdAt
        updatedAt = tag.updatedAt
        deletedAt = tag.deletedAt
        serverSeq = nil
        dirty = true
    }

    var tag: Tag {
        Tag(id: UUID(uuidString: id)!, userId: userId, name: name, colorHex: colorHex,
            sortOrder: sortOrder, createdAt: createdAt, updatedAt: updatedAt,
            deletedAt: deletedAt)
    }
}

struct HabitTagRow: SnakeCaseRecord {
    static let databaseTableName = "habit_tag"

    var habitId: String
    var tagId: String
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?
    /// Die `id` der Zeile, mit der diese zusammen gelöscht wurde — `nil` bei
    /// eigenständiger Löschung. Nur aussagekräftig, solange `deletedAt` steht.
    var deletedWith: String?
    var serverSeq: Int64?
    var dirty: Bool
}

// MARK: - entry

struct EntryRow: SnakeCaseRecord {
    static let databaseTableName = "entry"

    var id: String
    var userId: String
    var habitId: String
    var date: CalendarDate
    var value: Double
    var note: String?
    var source: EntrySource
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?
    /// Die `id` der Zeile, mit der diese zusammen gelöscht wurde — `nil` bei
    /// eigenständiger Löschung. Nur aussagekräftig, solange `deletedAt` steht.
    var deletedWith: String?
    var serverSeq: Int64?
    var dirty: Bool

    init(_ entry: Entry, userId: String) {
        id = entry.id.uuidString
        self.userId = userId
        habitId = entry.habitId.uuidString
        date = entry.date
        value = entry.value
        note = entry.note
        source = entry.source
        createdAt = entry.createdAt
        updatedAt = entry.updatedAt
        deletedAt = entry.deletedAt
        deletedWith = nil
        serverSeq = nil
        dirty = true
    }

    var entry: Entry {
        Entry(id: UUID(uuidString: id)!, habitId: UUID(uuidString: habitId)!,
              date: date, value: value, note: note, source: source,
              createdAt: createdAt, updatedAt: updatedAt, deletedAt: deletedAt)
    }
}

// MARK: - entry_event

struct EntryEventRow: SnakeCaseRecord {
    static let databaseTableName = "entry_event"

    var id: String
    var habitId: String
    var date: CalendarDate
    var at: Date
    var value: Double
    var note: String?
    var source: EntrySource
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?
    /// Die `id` der Zeile, mit der diese zusammen gelöscht wurde — `nil` bei
    /// eigenständiger Löschung. Nur aussagekräftig, solange `deletedAt` steht.
    var deletedWith: String?
    var serverSeq: Int64?
    var dirty: Bool

    init(_ event: EntryEvent) {
        id = event.id.uuidString
        habitId = event.habitId.uuidString
        date = event.date
        at = event.at
        value = event.value
        note = event.note
        source = event.source
        createdAt = event.createdAt
        updatedAt = event.updatedAt
        deletedAt = event.deletedAt
        deletedWith = nil
        serverSeq = nil
        dirty = true
    }

    var event: EntryEvent {
        EntryEvent(id: UUID(uuidString: id)!, habitId: UUID(uuidString: habitId)!,
                   date: date, at: at, value: value, note: note, source: source,
                   createdAt: createdAt, updatedAt: updatedAt, deletedAt: deletedAt)
    }
}

// MARK: - day_exception

struct DayExceptionRow: SnakeCaseRecord {
    static let databaseTableName = "day_exception"

    var id: String
    var userId: String
    var habitId: String?
    var date: CalendarDate
    var kind: ExceptionKind
    var reason: String?
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?
    /// Die `id` der Zeile, mit der diese zusammen gelöscht wurde — `nil` bei
    /// eigenständiger Löschung. Nur aussagekräftig, solange `deletedAt` steht.
    var deletedWith: String?
    var serverSeq: Int64?
    var dirty: Bool

    init(_ exception: DayException, userId: String) {
        id = exception.id.uuidString
        self.userId = userId
        habitId = exception.habitId?.uuidString
        date = exception.date
        kind = exception.kind
        reason = exception.reason
        createdAt = exception.createdAt
        updatedAt = exception.updatedAt
        deletedAt = exception.deletedAt
        deletedWith = nil
        serverSeq = nil
        dirty = true
    }

    var exception: DayException {
        DayException(id: UUID(uuidString: id)!,
                     habitId: habitId.flatMap(UUID.init(uuidString:)),
                     date: date, kind: kind, reason: reason,
                     createdAt: createdAt, updatedAt: updatedAt, deletedAt: deletedAt)
    }
}

// MARK: - day_log

struct DayLogRow: SnakeCaseRecord {
    static let databaseTableName = "day_log"

    var userId: String
    var date: CalendarDate
    var mood: Int?
    var energy: Int?
    var sleepHours: Double?
    var note: String?
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?
    var serverSeq: Int64?
    var dirty: Bool

    init(_ log: DayLog) {
        userId = log.userId
        date = log.date
        mood = log.mood
        energy = log.energy
        sleepHours = log.sleepHours
        note = log.note
        createdAt = log.createdAt
        updatedAt = log.updatedAt
        deletedAt = log.deletedAt
        serverSeq = nil
        dirty = true
    }

    var log: DayLog {
        DayLog(date: date, userId: userId, mood: mood, energy: energy,
               sleepHours: sleepHours, note: note, createdAt: createdAt,
               updatedAt: updatedAt, deletedAt: deletedAt)
    }
}

// MARK: - focus_run

struct FocusRunRow: SnakeCaseRecord {
    static let databaseTableName = "focus_run"

    var id: String
    var userId: String
    var title: String?
    var startsOn: CalendarDate
    var endsOn: CalendarDate
    var habitIds: String            // JSON
    var abandonedOn: CalendarDate?
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?
    var serverSeq: Int64?
    var dirty: Bool

    init(_ focus: FocusRun) throws {
        id = focus.id.uuidString
        userId = focus.userId
        title = focus.title
        startsOn = focus.startsOn
        endsOn = focus.endsOn
        habitIds = try JSONColumn.encode(focus.habitIds.map(\.uuidString))
        abandonedOn = focus.abandonedOn
        createdAt = focus.createdAt
        updatedAt = focus.updatedAt
        deletedAt = focus.deletedAt
        serverSeq = nil
        dirty = true
    }

    var focus: FocusRun {
        get throws {
            FocusRun(
                id: UUID(uuidString: id)!, userId: userId, title: title,
                startsOn: startsOn, endsOn: endsOn,
                habitIds: try JSONColumn.decode([String].self, from: habitIds)
                    .compactMap(UUID.init(uuidString:)),
                abandonedOn: abandonedOn, createdAt: createdAt,
                updatedAt: updatedAt, deletedAt: deletedAt)
        }
    }
}
