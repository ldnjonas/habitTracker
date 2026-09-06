import Foundation
import HabitCore
import HabitStore

/// Wie ein Abgleich ausging.
public struct SyncResult: Hashable, Sendable {
    public var hochgeladen: Int
    public var verworfen: Int
    public var uebernommen: Int
    public var neuerCursor: Int64

    public var summary: String {
        var teile: [String] = []
        if hochgeladen > 0 { teile.append("\(hochgeladen) gesendet") }
        if uebernommen > 0 { teile.append("\(uebernommen) empfangen") }
        if verworfen > 0 { teile.append("\(verworfen) abgelehnt") }
        return teile.isEmpty ? "nichts zu tun" : teile.joined(separator: " · ")
    }
}

/// Gleicht die lokale Datenbank mit dem Server ab.
///
/// **Erst senden, dann holen.** In dieser Reihenfolge kommen die eigenen
/// Änderungen mit den autoritativen Werten des Servers zurück — gestutzte
/// Zeitstempel, vergebene Sequenznummern — und der Client übernimmt dessen
/// Fassung, statt seiner eigenen zu vertrauen. Umgekehrt würde er erst fremde
/// Werte einbauen und sie gleich darauf mit seinen überschreiben.
public actor SyncEngine {
    private let store: LocalHabitAPI
    private let transport: any SyncTransport
    /// Wie viele Zeilen ein Durchgang höchstens holt.
    private let seitengroesse: Int

    public private(set) var läuft = false
    public private(set) var letzterFehler: String?
    public private(set) var letzterErfolg: Date?

    public init(store: LocalHabitAPI, transport: any SyncTransport, seitengroesse: Int = 500) {
        self.store = store
        self.transport = transport
        self.seitengroesse = seitengroesse
    }

    /// Ein vollständiger Abgleich.
    ///
    /// Läuft schon einer, kehrt der Aufruf zurück, statt einen zweiten zu
    /// starten: zwei gleichzeitige Durchgänge würden einander die Markierungen
    /// unter den Füßen wegziehen.
    @discardableResult
    public func sync() async throws -> SyncResult {
        guard !läuft else { return SyncResult(hochgeladen: 0, verworfen: 0, uebernommen: 0,
                                              neuerCursor: try await store.syncState().lastServerSeq) }
        läuft = true
        defer { läuft = false }

        do {
            try await pruefeHerkunft()
            let bericht = try await sende()
            let empfangen = try await hole()
            letzterFehler = nil
            letzterErfolg = Date()
            return SyncResult(hochgeladen: bericht.angenommen,
                              verworfen: bericht.verworfen,
                              uebernommen: empfangen.uebernommen,
                              neuerCursor: empfangen.cursor)
        } catch {
            letzterFehler = String(describing: error)
            throw error
        }
    }

    // MARK: - Mit wem rede ich hier

    /// Prüft, ob der Server noch derselbe ist wie beim letzten Abgleich.
    ///
    /// Der Cursor allein ist wertlos, solange nicht feststeht, worauf er sich
    /// bezieht. „Bis Sequenz 695 übertragen" gilt für **eine** Datenbank; steht
    /// am selben Ort eine andere, hat der Client nichts mehr zu senden — alles
    /// gilt als bekannt — und fragt nach Zeilen jenseits von 695, die es dort
    /// nie geben wird. Beide Seiten halten sich für fertig, und der Bestand
    /// fehlt zur Hälfte. Genau das ist einmal passiert: neun Habits, drei
    /// angekommen.
    ///
    /// Zwei Anlässe für einen Neuanfang, und der zweite ist der stillere:
    /// eine andere Kennung (neue oder fremde Datenbank) und eine Sequenz, die
    /// **unter** dem eigenen Cursor liegt (aus einer alten Kopie
    /// wiederhergestellt).
    private func pruefeHerkunft() async throws {
        let auskunft = try await transport.info()
        guard let kennung = auskunft.instance else { return }   // ältere Serverfassung
        let stand = try await store.syncState()

        let andere = stand.serverInstance != kennung
        let zurueckgesetzt = (auskunft.seq ?? 0) < stand.lastServerSeq
        guard andere || zurueckgesetzt else { return }

        try await store.beginneVonVorn(serverInstance: kennung)
    }

    // MARK: - Senden

    private func sende() async throws -> SyncReport {
        let offen = try await store.pendingChanges()
        guard !offen.isEmpty else {
            return SyncReport(angenommen: 0, verworfen: 0,
                              nextSeq: try await store.syncState().lastServerSeq)
        }

        // Den Stand festhalten, **bevor** gesendet wird: was sich währenddessen
        // ändert, darf hinterher nicht als übertragen gelten.
        let marken = marken(fuer: offen)
        let bericht = try await transport.push(delta(aus: offen))
        try await store.clearDirty(marken)
        return bericht
    }

    private func delta(aus zeilen: SyncDeltaRows) -> SyncDelta {
        SyncDelta(habits: zeilen.habits, tags: zeilen.tags, entries: zeilen.entries,
                  events: zeilen.events, exceptions: zeilen.exceptions,
                  dayLogs: zeilen.dayLogs, focusRuns: zeilen.focusRuns,
                  freezes: zeilen.freezes)
    }

    private func marken(fuer zeilen: SyncDeltaRows) -> [SyncMark] {
        func mark(_ tabelle: String, _ id: UUID, _ stempel: Date) -> SyncMark {
            SyncMark(tabelle: tabelle, bedingung: "id = ?",
                     werte: [id.uuidString], updatedAt: stempel)
        }
        var alle: [SyncMark] = []
        alle += zeilen.habits.map { mark("habit", $0.id, $0.updatedAt) }
        alle += zeilen.tags.map { mark("tag", $0.id, $0.updatedAt) }
        alle += zeilen.entries.map { mark("entry", $0.id, $0.updatedAt) }
        alle += zeilen.events.map { mark("entry_event", $0.id, $0.updatedAt) }
        alle += zeilen.exceptions.map { mark("day_exception", $0.id, $0.updatedAt) }
        alle += zeilen.focusRuns.map { mark("focus_run", $0.id, $0.updatedAt) }
        alle += zeilen.dayLogs.map {
            SyncMark(tabelle: "day_log", bedingung: "user_id = ? AND date = ?",
                     werte: [$0.userId, $0.date.description], updatedAt: $0.updatedAt)
        }
        // Buchungen ändern sich nie und führen deshalb gar kein `updated_at`.
        // Ohne Stempel entfällt die Prüfung — es gibt nichts zu prüfen.
        alle += zeilen.freezes.map {
            SyncMark(tabelle: "freeze_ledger", bedingung: "id = ?",
                     werte: [$0.id.uuidString], updatedAt: nil)
        }
        return alle
    }

    // MARK: - Holen

    private func hole() async throws -> (uebernommen: Int, cursor: Int64) {
        var cursor = try await store.syncState().lastServerSeq
        var gesamt = 0

        // Der Server schneidet an einer Sequenznummer ab und sagt es. So lange
        // weiterlesen, bis er nichts mehr hat — sonst bliebe ein großer
        // Rückstand für immer halb geholt.
        while true {
            let delta = try await transport.pull(since: cursor, limit: seitengroesse)
            guard let naechster = delta.nextSeq else { break }
            if !delta.isEmpty || naechster > cursor {
                gesamt += try await store.applyDelta(zeilen(aus: delta), nextSeq: naechster)
                cursor = naechster
            }
            guard delta.hasMore == true else { break }
        }
        return (gesamt, cursor)
    }

    private func zeilen(aus delta: SyncDelta) -> SyncDeltaRows {
        SyncDeltaRows(habits: delta.habits, tags: delta.tags, entries: delta.entries,
                      events: delta.events, exceptions: delta.exceptions,
                      dayLogs: delta.dayLogs, focusRuns: delta.focusRuns,
                      freezes: delta.freezes)
    }
}
