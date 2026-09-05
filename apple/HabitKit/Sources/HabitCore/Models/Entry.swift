import Foundation

/// Der autoritative Tagesdatensatz. **Nur diesen liest die Streak-Engine.**
///
/// Adressiert wird er über `(habitId, date)`, nicht über `id` — dadurch ist das
/// Schreiben idempotent und ein Sync-Konflikt („beide Geräte haben heute
/// abgehakt") löst sich von selbst auf.
public struct Entry: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var habitId: UUID
    public var date: CalendarDate
    /// `binary`: 0 oder 1 · `quantity`: die Menge · `avoid`: Anzahl Verstöße.
    public var value: Double
    public var note: String?
    public var source: EntrySource
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(
        id: UUID = UUID(),
        habitId: UUID,
        date: CalendarDate,
        value: Double,
        note: String? = nil,
        source: EntrySource = .manual,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.habitId = habitId
        self.date = date
        self.value = value
        self.note = note
        self.source = source
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

/// Optionales Zeitstempel-Detail für Habits mit `tracksTime`.
///
/// Summiert sich zu `Entry.value` — die Invariante hält der Store, nicht der
/// Aufrufer. `HabitCore` kennt diesen Typ absichtlich nur als Datenmodell und
/// wertet ihn nirgends aus.
public struct EntryEvent: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var habitId: UUID
    /// Der lokale Tag, zu dem das Event zählt — denormalisiert, damit die
    /// Tageszuordnung nicht von der Zeitzone des Lesers abhängt.
    public var date: CalendarDate
    /// Beginn der Sitzung.
    public var at: Date
    /// Ende, wenn es eine Sitzung mit Dauer ist.
    ///
    /// Ist es gesetzt, **leitet der Store `value` daraus ab** (Minuten), statt
    /// es vom Aufrufer zu übernehmen. Zwei Felder, die dasselbe sagen, driften
    /// sonst auseinander — dieselbe Begründung, aus der nicht der Aufrufer,
    /// sondern der Store die Tagessumme hält.
    public var endsAt: Date?
    public var value: Double
    public var note: String?
    public var source: EntrySource
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(
        id: UUID = UUID(),
        habitId: UUID,
        date: CalendarDate,
        at: Date,
        endsAt: Date? = nil,
        value: Double,
        note: String? = nil,
        source: EntrySource = .manual,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.habitId = habitId
        self.date = date
        self.at = at
        self.endsAt = endsAt
        self.value = value
        self.note = note
        self.source = source
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    /// Dauer in Minuten — `nil`, solange kein Ende gesetzt ist.
    public var durationMinutes: Double? {
        endsAt.map { $0.timeIntervalSince(at) / 60 }
    }

    /// Der Wert, der für diesen Eintrag zählt.
    ///
    /// Bei einer Sitzung mit Ende die Dauer, sonst der gesetzte Wert. Der Store
    /// schreibt genau das in die Spalte, damit die Tagessumme stimmt, ohne dass
    /// jemand beide Felder von Hand im Einklang halten muss.
    public var effectiveValue: Double {
        durationMinutes ?? value
    }

    /// Ob Start und Ende zueinander passen. Ein Ende vor dem Start ist kein
    /// Grenzfall, sondern ein Tippfehler.
    public var hasValidInterval: Bool {
        guard let endsAt else { return true }
        return endsAt > at
    }
}

/// Warum ein geplanter Tag nicht als verpasst zählt.
///
/// Streak Freeze, Urlaub und bewusster Ruhetag sind für die Engine dasselbe
/// Konzept — sie unterscheiden sich nur darin, wie sie in die Statistik eingehen.
public enum ExceptionKind: String, Codable, CaseIterable, Sendable, Hashable {
    /// Eingelöster Token: schützt den Streak, zählt aber weiter als verpasst.
    case frozen
    /// Urlaub: der Tag war nie vorgesehen, fällt ganz aus der Statistik.
    case paused
    /// Bewusster Ruhetag: wie `paused`, nur manuell für einen einzelnen Tag.
    case skipped

    /// Ob der Tag so behandelt wird, als wäre er nie geplant gewesen.
    public var removesDayFromSchedule: Bool { self != .frozen }
}

public struct DayException: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    /// `nil` heißt: gilt für alle Habits (Urlaub).
    public var habitId: UUID?
    public var date: CalendarDate
    public var kind: ExceptionKind
    public var reason: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(
        id: UUID = UUID(),
        habitId: UUID? = nil,
        date: CalendarDate,
        kind: ExceptionKind,
        reason: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.habitId = habitId
        self.date = date
        self.kind = kind
        self.reason = reason
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

/// Tages-Journal, unabhängig von einzelnen Habits. Basis für die
/// Korrelations-Auswertung.
public struct DayLog: Codable, Hashable, Sendable {
    public var date: CalendarDate
    public var userId: String
    public var mood: Int?          // 1...5
    public var energy: Int?        // 1...5
    public var sleepHours: Double?
    public var note: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(
        date: CalendarDate,
        userId: String = Habit.localUserId,
        mood: Int? = nil,
        energy: Int? = nil,
        sleepHours: Double? = nil,
        note: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.date = date
        self.userId = userId
        self.mood = mood
        self.energy = energy
        self.sleepHours = sleepHours
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}
