import Foundation
import GRDB
import HabitCore

/// Was der Cursor über den letzten Abgleich weiß.
public struct SyncState: Hashable, Sendable {
    public var lastServerSeq: Int64
    public var lastSyncedAt: Date?
    /// Die Kennung der Server-Datenbank, für die `lastServerSeq` gilt.
    ///
    /// `nil` heißt: noch nie abgeglichen — oder mit einer Fassung, die diese
    /// Frage nicht gestellt hat. Beides führt zum vollständigen Neuabgleich,
    /// und das ist die sichere Richtung.
    public var serverInstance: String?
}

extension LocalHabitAPI {

    // MARK: - Cursor

    public func syncState() async throws -> SyncState {
        try await dbQueue.read { db in
            let zeile = try Row.fetchOne(db, sql: """
                SELECT last_server_seq, last_synced_at, server_instance
                FROM sync_state WHERE id = 1
                """)
            return SyncState(lastServerSeq: zeile?["last_server_seq"] ?? 0,
                             lastSyncedAt: zeile?["last_synced_at"],
                             serverInstance: zeile?["server_instance"])
        }
    }

    /// Setzt den Abgleich auf Anfang — für eine Server-Datenbank, die diesen
    /// Client noch nicht kennt.
    ///
    /// Zwei Dinge zugleich, und beide sind nötig: der Cursor geht auf null,
    /// damit wieder alles geholt wird, und **jede Zeile wird als offen
    /// markiert**, damit wieder alles gesendet wird. Nur das eine zu tun hieße,
    /// die Hälfte des Bestands stillschweigend zurückzulassen — genau der
    /// Fehler, den diese Funktion behebt.
    ///
    /// `habit_rule` und `habit_tag` stehen nicht in der Liste: sie wandern mit
    /// ihrem Habit und tragen keine eigene Sequenznummer.
    public func beginneVonVorn(serverInstance: String) async throws {
        try await dbQueue.write { db in
            for tabelle in ["habit", "tag", "entry", "entry_event",
                            "day_exception", "day_log", "focus_run", "freeze_ledger"] {
                try db.execute(sql: "UPDATE \"\(tabelle)\" SET dirty = 1")
            }
            try db.execute(sql: """
                UPDATE sync_state
                SET last_server_seq = 0, server_instance = ?
                WHERE id = 1
                """, arguments: [serverInstance])
        }
    }

    // MARK: - Einsammeln

    /// Alles, was seit dem letzten Abgleich lokal geändert wurde.
    ///
    /// Regeln und Tag-Zuordnungen kommen nicht als eigene Listen: sie wandern
    /// mit ihrem Habit. Deshalb hebt jede Änderung an ihnen `updated_at` des
    /// Habits an (`touchHabit`) — ohne das bliebe sie hier unsichtbar.
    public func pendingChanges() async throws -> SyncDeltaRows {
        try await dbQueue.read { [userId] db in
            func habits() throws -> [Habit] {
                try HabitRow.fetchAll(db, sql: "SELECT * FROM habit WHERE dirty = 1")
                    .map { try LocalHabitAPI.assembleForSync($0, db: db) }
            }
            return SyncDeltaRows(
                habits: try habits(),
                tags: try TagRow.fetchAll(db, sql: "SELECT * FROM tag WHERE dirty = 1")
                    .map(\.tag),
                entries: try EntryRow.fetchAll(db, sql: "SELECT * FROM entry WHERE dirty = 1")
                    .map(\.entry),
                events: try EntryEventRow.fetchAll(db, sql: "SELECT * FROM entry_event WHERE dirty = 1")
                    .map(\.event),
                exceptions: try DayExceptionRow.fetchAll(db, sql: "SELECT * FROM day_exception WHERE dirty = 1")
                    .map(\.exception),
                dayLogs: try DayLogRow.fetchAll(db, sql: "SELECT * FROM day_log WHERE dirty = 1")
                    .map(\.log),
                focusRuns: try FocusRunRow.fetchAll(db, sql: "SELECT * FROM focus_run WHERE dirty = 1")
                    .map { try $0.focus },
                freezes: try FreezeRow.fetchAll(db, sql: "SELECT * FROM freeze_ledger WHERE dirty = 1")
                    .map(\.entry))
        }
    }

    /// Wie `assemble`, aber **einschließlich gelöschter** Regeln und Tags nicht:
    /// eine Löschung drückt sich darin aus, dass die Zeile fehlt. Der Server
    /// ersetzt beides als Einheit.
    static func assembleForSync(_ row: HabitRow, db: Database) throws -> Habit {
        try assemble(row, db: db)
    }

    // MARK: - Anwenden

    /// Übernimmt ein Delta vom Server.
    ///
    /// Drei Regeln, alle nötig:
    ///
    /// 1. **Last-Write-Wins auf `updatedAt`.** Eine lokal neuere Zeile bleibt
    ///    stehen und wird beim nächsten Hochladen ihrerseits gewinnen.
    /// 2. **Angewandte Zeilen sind nicht mehr `dirty`.** Sie kommen vom Server,
    ///    also kennt er sie schon.
    /// 3. **Grabsteine werden angewandt.** Eine Zeile mit `deletedAt` wird auch
    ///    lokal gelöscht — sonst käme die Löschung nie an.
    ///
    /// Alles in einer Transaktion samt Cursor: ein halb angewandtes Delta mit
    /// fortgeschriebenem Cursor würde die fehlenden Zeilen nie wieder holen.
    @discardableResult
    public func applyDelta(_ delta: SyncDeltaRows, nextSeq: Int64, at now: Date = Date()) async throws -> Int {
        try await dbQueue.write { [userId] db in
            var angewandt = 0

            // Tags zuerst: `habit_tag` verweist auf sie, und ein Habit bringt
            // seine Zuordnungen mit. In umgekehrter Reihenfolge scheitert der
            // Fremdschlüssel und ein ganzer Abgleich bricht ab.
            for tag in delta.tags {
                var row = TagRow(tag); row.userId = userId; row.dirty = false
                if try Self.uebernehmen(row.id, "tag", tag.updatedAt, db: db) {
                    try row.upsert(db); angewandt += 1
                }
            }
            for habit in delta.habits {
                var row = try HabitRow(habit)
                row.userId = userId
                row.dirty = false
                if try Self.uebernehmen(row.id, "habit", habit.updatedAt, db: db) {
                    try row.upsert(db)
                    try Self.replaceRulesAndTags(habit, db: db)
                    angewandt += 1
                }
            }
            for entry in delta.entries {
                var row = EntryRow(entry, userId: userId); row.dirty = false
                if try Self.uebernehmen(row.id, "entry", entry.updatedAt, db: db) {
                    try row.upsert(db); angewandt += 1
                }
            }
            for event in delta.events {
                var row = EntryEventRow(event); row.dirty = false
                if try Self.uebernehmen(row.id, "entry_event", event.updatedAt, db: db) {
                    try row.upsert(db); angewandt += 1
                }
            }
            for exception in delta.exceptions {
                var row = DayExceptionRow(exception, userId: userId); row.dirty = false
                if try Self.uebernehmen(row.id, "day_exception", exception.updatedAt, db: db) {
                    try row.upsert(db); angewandt += 1
                }
            }
            for log in delta.dayLogs {
                var row = DayLogRow(log); row.userId = userId; row.dirty = false
                let vorhanden = try Date.fetchOne(db, sql: """
                    SELECT updated_at FROM day_log WHERE user_id = ? AND date = ?
                    """, arguments: [userId, log.date])
                if vorhanden == nil || log.updatedAt > vorhanden! {
                    try row.upsert(db); angewandt += 1
                }
            }
            for run in delta.focusRuns {
                var row = try FocusRunRow(run); row.userId = userId; row.dirty = false
                if try Self.uebernehmen(row.id, "focus_run", run.updatedAt, db: db) {
                    try row.upsert(db); angewandt += 1
                }
            }
            // Buchungen kennen keinen Konflikt: entweder sie sind da oder nicht.
            for freeze in delta.freezes {
                var row = FreezeRow(freeze); row.userId = userId; row.dirty = false
                let vorhanden = try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM freeze_ledger WHERE id = ?",
                    arguments: [row.id]) ?? 0
                if vorhanden == 0 { try row.insert(db); angewandt += 1 }
            }

            try db.execute(sql: """
                UPDATE sync_state SET last_server_seq = ?, last_synced_at = ? WHERE id = 1
                """, arguments: [nextSeq, now])
            return angewandt
        }
    }

    /// Ob die Fassung vom Server die lokale ablösen darf.
    private static func uebernehmen(
        _ id: String, _ tabelle: String, _ stempel: Date, db: Database
    ) throws -> Bool {
        let vorhanden = try Date.fetchOne(
            db, sql: "SELECT updated_at FROM \"\(tabelle)\" WHERE id = ?", arguments: [id])
        guard let vorhanden else { return true }
        return stempel > vorhanden
    }

    /// Regeln und Tags werden mit dem Habit als Einheit ersetzt — dieselbe
    /// Entscheidung wie beim Einspielen einer Sicherung.
    private static func replaceRulesAndTags(_ habit: Habit, db: Database) throws {
        try db.execute(sql: "DELETE FROM habit_rule WHERE habit_id = ?",
                       arguments: [habit.id.uuidString])
        for rule in habit.rules {
            var row = try HabitRuleRow(habitId: habit.id, rule: rule, now: habit.updatedAt)
            row.dirty = false
            try row.insert(db)
        }
        try db.execute(sql: "DELETE FROM habit_tag WHERE habit_id = ?",
                       arguments: [habit.id.uuidString])
        // Zusätzlich absichern: die Reihenfolge oben deckt den Regelfall ab,
        // aber ein unbekannter Tag darf niemals einen ganzen Abgleich
        // abbrechen. Er kommt mit dem nächsten Anfassen des Habits nach.
        let bekannt = Set(try String.fetchAll(db, sql: "SELECT id FROM tag"))
        for tagId in habit.tagIds where bekannt.contains(tagId.uuidString) {
            var row = HabitTagRow(habitId: habit.id.uuidString, tagId: tagId.uuidString,
                                  createdAt: habit.createdAt, updatedAt: habit.updatedAt,
                                  deletedAt: nil, serverSeq: nil, dirty: false)
            try row.insert(db)
        }
    }

    /// Nimmt die Markierung von genau den Zeilen, die hochgeladen wurden — und
    /// nur, wenn sie sich seither nicht wieder geändert haben.
    ///
    /// Ohne diese Prüfung ginge eine Änderung verloren, die während des
    /// Hochladens entsteht: sie wäre als übertragen markiert, ohne es zu sein.
    public func clearDirty(_ marken: [SyncMark]) async throws {
        try await dbQueue.write { db in
            for marke in marken {
                var werte = marke.werte.map { $0 as DatabaseValueConvertible }
                var bedingung = marke.bedingung
                // Ohne Zeitstempel keine Prüfung: das Freeze-Konto führt
                // absichtlich kein `updated_at`, weil eine Buchung sich nie
                // ändert. Dort ist die Prüfung nicht nur unnötig, sondern
                // unmöglich — und der Versuch reißt die ganze Transaktion mit,
                // sodass am Ende gar nichts quittiert wäre.
                if let stempel = marke.updatedAt {
                    bedingung += " AND updated_at = ?"
                    werte.append(stempel)
                }
                try db.execute(
                    sql: "UPDATE \"\(marke.tabelle)\" SET dirty = 0 WHERE \(bedingung)",
                    arguments: StatementArguments(werte))
            }
        }
    }
}

/// Eine hochgeladene Zeile mit dem Stand, den sie dabei hatte.
public struct SyncMark: Sendable {
    public let tabelle: String
    public let bedingung: String
    /// Die Werte des Primärschlüssels. Durchweg Zeichenketten — auch der
    /// zusammengesetzte Schlüssel des Journals ist (Text, Text).
    public let werte: [String]
    /// Der Stand, den die Zeile beim Hochladen hatte. `nil`, wenn die Tabelle
    /// gar keinen führt — dann kann sie sich auch nicht geändert haben.
    public let updatedAt: Date?

    public init(tabelle: String, bedingung: String,
                werte: [String], updatedAt: Date?) {
        self.tabelle = tabelle
        self.bedingung = bedingung
        self.werte = werte
        self.updatedAt = updatedAt
    }
}

/// Die reinen Zeilen eines Deltas, ohne Cursor.
///
/// `HabitStore` kennt `HabitSync` nicht — die Abhängigkeit läuft andersherum.
/// Deshalb hier ein eigener Typ statt `SyncDelta`.
public struct SyncDeltaRows: Sendable {
    public var habits: [Habit]
    public var tags: [Tag]
    public var entries: [Entry]
    public var events: [EntryEvent]
    public var exceptions: [DayException]
    public var dayLogs: [DayLog]
    public var focusRuns: [FocusRun]
    public var freezes: [FreezeEntry]

    public init(
        habits: [Habit] = [], tags: [Tag] = [], entries: [Entry] = [],
        events: [EntryEvent] = [], exceptions: [DayException] = [],
        dayLogs: [DayLog] = [], focusRuns: [FocusRun] = [], freezes: [FreezeEntry] = []
    ) {
        self.habits = habits
        self.tags = tags
        self.entries = entries
        self.events = events
        self.exceptions = exceptions
        self.dayLogs = dayLogs
        self.focusRuns = focusRuns
        self.freezes = freezes
    }

    public var isEmpty: Bool {
        habits.isEmpty && tags.isEmpty && entries.isEmpty && events.isEmpty
            && exceptions.isEmpty && dayLogs.isEmpty && focusRuns.isEmpty && freezes.isEmpty
    }

    public var count: Int {
        habits.count + tags.count + entries.count + events.count
            + exceptions.count + dayLogs.count + focusRuns.count + freezes.count
    }
}
