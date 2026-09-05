import Foundation
import HabitCore

/// Was zwischen Client und Server hin- und hergeht.
///
/// Dieselben Formen wie die Sicherungsdatei: ein Habit kommt **samt seinen
/// Regeln und Tags**, nicht als drei getrennte Tabellen. Der Client hat die
/// Codable-Typen damit schon, und die Zerlegung bleibt Sache des Servers.
///
/// Ein Delta ist trotzdem etwas anderes als eine Sicherung, deshalb ein eigener
/// Typ: es enthält **Grabsteine** (Zeilen mit `deletedAt`) und trägt einen
/// Cursor. Eine Sicherung beschreibt einen Bestand, ein Delta eine Veränderung.
public struct SyncDelta: Codable, Hashable, Sendable {
    public var habits: [Habit]
    public var tags: [Tag]
    public var entries: [Entry]
    public var events: [EntryEvent]
    public var exceptions: [DayException]
    public var dayLogs: [DayLog]
    public var focusRuns: [FocusRun]
    public var freezes: [FreezeEntry]

    /// Der neue Cursor. Beim Hochladen nicht gesetzt.
    public var nextSeq: Int64?
    /// Ob noch mehr wartet und ein weiterer Durchgang nötig ist.
    public var hasMore: Bool?

    public init(
        habits: [Habit] = [], tags: [Tag] = [], entries: [Entry] = [],
        events: [EntryEvent] = [], exceptions: [DayException] = [],
        dayLogs: [DayLog] = [], focusRuns: [FocusRun] = [], freezes: [FreezeEntry] = [],
        nextSeq: Int64? = nil, hasMore: Bool? = nil
    ) {
        self.habits = habits
        self.tags = tags
        self.entries = entries
        self.events = events
        self.exceptions = exceptions
        self.dayLogs = dayLogs
        self.focusRuns = focusRuns
        self.freezes = freezes
        self.nextSeq = nextSeq
        self.hasMore = hasMore
    }

    /// Wie beim Sicherungsformat von Hand: fehlende Listen sind leer, kein
    /// Fehler. Sonst wäre jede neue Tabelle auf einer Seite ein Bruch.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        habits = try c.decodeIfPresent([Habit].self, forKey: .habits) ?? []
        tags = try c.decodeIfPresent([Tag].self, forKey: .tags) ?? []
        entries = try c.decodeIfPresent([Entry].self, forKey: .entries) ?? []
        events = try c.decodeIfPresent([EntryEvent].self, forKey: .events) ?? []
        exceptions = try c.decodeIfPresent([DayException].self, forKey: .exceptions) ?? []
        dayLogs = try c.decodeIfPresent([DayLog].self, forKey: .dayLogs) ?? []
        focusRuns = try c.decodeIfPresent([FocusRun].self, forKey: .focusRuns) ?? []
        freezes = try c.decodeIfPresent([FreezeEntry].self, forKey: .freezes) ?? []
        nextSeq = try c.decodeIfPresent(Int64.self, forKey: .nextSeq)
        hasMore = try c.decodeIfPresent(Bool.self, forKey: .hasMore)
    }

    public var isEmpty: Bool {
        habits.isEmpty && tags.isEmpty && entries.isEmpty && events.isEmpty
            && exceptions.isEmpty && dayLogs.isEmpty && focusRuns.isEmpty && freezes.isEmpty
    }

    public var count: Int {
        habits.count + tags.count + entries.count + events.count
            + exceptions.count + dayLogs.count + focusRuns.count + freezes.count
    }

    public var summary: String {
        var teile: [String] = []
        if !habits.isEmpty { teile.append("\(habits.count) Habits") }
        if !tags.isEmpty { teile.append("\(tags.count) Tags") }
        if !entries.isEmpty { teile.append("\(entries.count) Einträge") }
        if !events.isEmpty { teile.append("\(events.count) Sitzungen") }
        if !exceptions.isEmpty { teile.append("\(exceptions.count) Ausnahmen") }
        if !dayLogs.isEmpty { teile.append("\(dayLogs.count) Journaltage") }
        if !focusRuns.isEmpty { teile.append("\(focusRuns.count) Fokus-Läufe") }
        if !freezes.isEmpty { teile.append("\(freezes.count) Buchungen") }
        return teile.isEmpty ? "nichts" : teile.joined(separator: " · ")
    }
}

/// Was der Server zu einem hochgeladenen Delta meldet.
public struct SyncReport: Codable, Hashable, Sendable {
    public let angenommen: Int
    public let verworfen: Int
    public let nextSeq: Int64
}
