import Testing
import Foundation
import HabitCore
@testable import HabitStore
@testable import HabitSync

private let today = CalendarDate(iso: "2026-09-04")!
private func d(_ iso: String) -> CalendarDate { CalendarDate(iso: iso)! }

private func makeStore() throws -> LocalHabitAPI {
    try LocalHabitAPI.inMemory(currentDate: { today })
}

private func daily(_ name: String = "Sport") -> HabitDraft {
    HabitDraft(name: name, rules: [HabitRule(effectiveFrom: d("2026-08-01"), schedule: .daily)])
}

/// Ein Server im Speicher. Bildet die Regeln des echten nach — Sequenzfolge,
/// Last-Write-Wins, Grabsteine —, damit die Engine ohne Netz prüfbar ist.
private actor FakeServer: SyncTransport {
    private var zeilen: [(seq: Int64, delta: SyncDelta)] = []
    private var seq: Int64 = 0
    /// Wie viele Sequenzschritte ein `pull` höchstens liefert.
    var seitengroesse: Int64 = 1000
    private(set) var pushes = 0
    private(set) var pulls = 0
    /// Wie beim echten Server: die Kennung **dieser** Datenbank.
    private var kennung = UUID().uuidString

    func setSeitengroesse(_ wert: Int64) { seitengroesse = wert }

    func info() async throws -> ServerInfo {
        ServerInfo(instance: kennung, seq: seq)
    }

    /// Wirft die Datenbank weg und legt eine neue an — dasselbe, was passiert,
    /// wenn jemand die Serverdatei löscht oder einen zweiten Server aufsetzt.
    func fangeNeuAn() {
        zeilen = []
        seq = 0
        kennung = UUID().uuidString
    }

    /// Dieselbe Datenbank, aber aus einer älteren Kopie: die Kennung bleibt,
    /// der Stand fällt zurück.
    func spuleZurueck() {
        zeilen = []
        seq = 0
    }

    func push(_ delta: SyncDelta) async throws -> SyncReport {
        pushes += 1
        var angenommen = 0
        for teil in aufteilen(delta) {
            seq += 1
            zeilen.append((seq, teil))
            angenommen += 1
        }
        return SyncReport(angenommen: angenommen, verworfen: 0, nextSeq: seq)
    }

    func pull(since: Int64, limit: Int) async throws -> SyncDelta {
        pulls += 1
        let grenze = min(seq, since + seitengroesse)
        var ergebnis = SyncDelta()
        for eintrag in zeilen where eintrag.seq > since && eintrag.seq <= grenze {
            ergebnis.habits += eintrag.delta.habits
            ergebnis.tags += eintrag.delta.tags
            ergebnis.entries += eintrag.delta.entries
            ergebnis.events += eintrag.delta.events
            ergebnis.exceptions += eintrag.delta.exceptions
            ergebnis.dayLogs += eintrag.delta.dayLogs
            ergebnis.focusRuns += eintrag.delta.focusRuns
            ergebnis.freezes += eintrag.delta.freezes
        }
        ergebnis.nextSeq = grenze
        ergebnis.hasMore = grenze < seq
        return ergebnis
    }

    /// Legt Zeilen einzeln ab, damit jede ihre eigene Sequenznummer bekommt —
    /// wie im echten Server.
    private func aufteilen(_ delta: SyncDelta) -> [SyncDelta] {
        var teile: [SyncDelta] = []
        teile += delta.habits.map { SyncDelta(habits: [$0]) }
        teile += delta.tags.map { SyncDelta(tags: [$0]) }
        teile += delta.entries.map { SyncDelta(entries: [$0]) }
        teile += delta.events.map { SyncDelta(events: [$0]) }
        teile += delta.exceptions.map { SyncDelta(exceptions: [$0]) }
        teile += delta.dayLogs.map { SyncDelta(dayLogs: [$0]) }
        teile += delta.focusRuns.map { SyncDelta(focusRuns: [$0]) }
        teile += delta.freezes.map { SyncDelta(freezes: [$0]) }
        return teile
    }

    /// Etwas ablegen, als käme es von einem anderen Gerät.
    func lege(_ delta: SyncDelta) {
        for teil in aufteilen(delta) { seq += 1; zeilen.append((seq, teil)) }
    }
}

@Suite("Abgleich")
struct SyncEngineTests {

    @Test("Offene Änderungen gehen hoch und gelten danach als übertragen")
    func pushesPendingChanges() async throws {
        let store = try makeStore()
        let server = FakeServer()
        let habit = try await store.createHabit(daily())
        try await store.setEntry(habitId: habit.id, date: today, value: 1,
                                 note: nil, source: .manual)

        #expect(try await store.pendingChanges().count == 2)

        let engine = SyncEngine(store: store, transport: server)
        let ergebnis = try await engine.sync()
        #expect(ergebnis.hochgeladen == 2)
        #expect(try await store.pendingChanges().isEmpty, "nichts bleibt offen")
        #expect(try await store.syncState().lastServerSeq > 0)
    }

    /// Der Fehler, den erst der echte Betrieb gezeigt hat: neun Habits auf dem
    /// Mac, drei auf dem Server.
    ///
    /// Ein Cursor allein ist wertlos, solange nicht feststeht, worauf er sich
    /// bezieht. Nach einem Abgleich gilt jede Zeile als übertragen; steht dann
    /// eine andere Datenbank am selben Ort, hat der Client nichts mehr zu
    /// senden und fragt nach Zeilen jenseits seines Cursors, die es dort nie
    /// geben wird. Beide Seiten halten sich für fertig.
    @Test("Eine neue Server-Datenbank bekommt wieder den ganzen Bestand")
    func rebuildsAgainstAFreshServer() async throws {
        let store = try makeStore()
        let server = FakeServer()
        for name in ["Sport", "Lesen", "Wasser"] {
            _ = try await store.createHabit(daily(name))
        }

        let engine = SyncEngine(store: store, transport: server)
        #expect(try await engine.sync().hochgeladen == 3)
        #expect(try await store.pendingChanges().isEmpty)

        // Jemand löscht die Serverdatei und startet neu.
        await server.fangeNeuAn()

        // Ohne Herkunftsprüfung käme hier 0 heraus — und niemand sähe es.
        let zweiter = try await engine.sync()
        #expect(zweiter.hochgeladen == 3, "der ganze Bestand geht noch einmal hoch")
        #expect(try await store.pendingChanges().isEmpty)
        #expect(try await store.syncState().lastServerSeq > 0)
    }

    /// Der stillere Fall: dieselbe Datenbank, aber aus einer älteren Kopie
    /// wiederhergestellt. Die Kennung stimmt, der Stand ist zurückgefallen.
    @Test("Ein zurückgesetzter Server bekommt den Bestand ebenfalls wieder")
    func rebuildsAgainstARewoundServer() async throws {
        let store = try makeStore()
        let server = FakeServer()
        _ = try await store.createHabit(daily())

        let engine = SyncEngine(store: store, transport: server)
        #expect(try await engine.sync().hochgeladen == 1)

        await server.spuleZurueck()
        #expect(try await engine.sync().hochgeladen == 1)
    }

    @Test("Was ein anderes Gerät geschrieben hat, kommt an")
    func pullsRemoteChanges() async throws {
        let store = try makeStore()
        let server = FakeServer()
        let fremd = Habit(name: "Laufen",
                          rules: [HabitRule(effectiveFrom: d("2026-08-01"),
                                            schedule: .timesPerWeek(3))])
        await server.lege(SyncDelta(habits: [fremd]))

        let engine = SyncEngine(store: store, transport: server)
        let ergebnis = try await engine.sync()

        #expect(ergebnis.uebernommen == 1)
        let habits = try await store.listHabits(includeArchived: true)
        #expect(habits.map(\.name) == ["Laufen"])
        #expect(habits[0].rule(on: today)?.schedule == .timesPerWeek(3), "die Regel kam mit")
        // Empfangenes ist nicht offen: der Server kennt es ja.
        #expect(try await store.pendingChanges().isEmpty)
    }

    /// Ohne das käme eine Löschung nie an — der Eintrag stünde auf dem zweiten
    /// Gerät weiter, und niemand wüsste, warum.
    @Test("Ein Grabstein löscht auch lokal")
    func appliesTombstones() async throws {
        let store = try makeStore()
        let server = FakeServer()
        let habit = try await store.createHabit(daily())
        try await store.setEntry(habitId: habit.id, date: today, value: 1,
                                 note: nil, source: .manual)
        let engine = SyncEngine(store: store, transport: server)
        try await engine.sync()

        let eintrag = try #require(try await store.entries(habitId: habit.id,
                                                          from: today, to: today).first)
        var grabstein = eintrag
        grabstein.deletedAt = Date()
        grabstein.updatedAt = Date().addingTimeInterval(60)
        await server.lege(SyncDelta(entries: [grabstein]))

        try await engine.sync()
        #expect(try await store.entries(habitId: habit.id, from: today, to: today).isEmpty)
    }

    @Test("Die lokal neuere Fassung überlebt und gewinnt beim nächsten Senden")
    func localNewerWins() async throws {
        let store = try makeStore()
        let server = FakeServer()
        let habit = try await store.createHabit(daily())
        try await store.setEntry(habitId: habit.id, date: today, value: 5,
                                 note: nil, source: .manual)
        let engine = SyncEngine(store: store, transport: server)
        try await engine.sync()

        // Eine ältere Fassung vom Server darf die neuere lokale nicht ablösen.
        var alt = try #require(try await store.entries(habitId: habit.id,
                                                       from: today, to: today).first)
        alt.value = 99
        alt.updatedAt = Date().addingTimeInterval(-3600)
        await server.lege(SyncDelta(entries: [alt]))

        try await engine.sync()
        #expect(try await store.entries(habitId: habit.id, from: today, to: today)
                    .first?.value == 5)
    }

    /// Der Grund für die Zeitstempel-Prüfung beim Aufheben der Markierung.
    @Test("Eine Änderung während des Sendens bleibt offen")
    func changeDuringPushStaysPending() async throws {
        let store = try makeStore()
        let habit = try await store.createHabit(daily())
        try await store.setEntry(habitId: habit.id, date: today, value: 1,
                                 note: nil, source: .manual)

        // Ein Transport, der mitten im Senden noch etwas ändert — so wie es
        // passiert, wenn jemand während des Abgleichs abhakt.
        actor Störer: SyncTransport {
            let store: LocalHabitAPI
            let habitId: UUID
            init(store: LocalHabitAPI, habitId: UUID) {
                self.store = store; self.habitId = habitId
            }
            // Ohne Kennung — wie ein Server aus der Zeit vor der Herkunftsprüfung.
            // Hier geht es um das Markieren während des Sendens, nicht um sie.
            func info() async throws -> ServerInfo { ServerInfo(instance: nil, seq: 0) }
            func pull(since: Int64, limit: Int) async throws -> SyncDelta {
                SyncDelta(nextSeq: since, hasMore: false)
            }
            func push(_ delta: SyncDelta) async throws -> SyncReport {
                try await store.setEntry(habitId: habitId, date: today, value: 42,
                                         note: nil, source: .manual)
                return SyncReport(angenommen: delta.count, verworfen: 0, nextSeq: 1)
            }
        }

        let engine = SyncEngine(store: store, transport: Störer(store: store, habitId: habit.id))
        try await engine.sync()

        let offen = try await store.pendingChanges()
        #expect(offen.entries.count == 1, "die zwischenzeitliche Änderung ist noch offen")
        #expect(offen.entries.first?.value == 42)
    }

    @Test("Ein großer Rückstand wird in mehreren Durchgängen geholt")
    func pullsInPages() async throws {
        let store = try makeStore()
        let server = FakeServer()
        let habit = Habit(name: "Sport",
                          rules: [HabitRule(effectiveFrom: d("2026-08-01"), schedule: .daily)])
        await server.lege(SyncDelta(habits: [habit]))
        for tag in 1...12 {
            await server.lege(SyncDelta(entries: [
                Entry(habitId: habit.id, date: d(String(format: "2026-08-%02d", tag)), value: 1)]))
        }
        await server.setSeitengroesse(4)

        let engine = SyncEngine(store: store, transport: server, seitengroesse: 4)
        let ergebnis = try await engine.sync()

        #expect(ergebnis.uebernommen == 13)
        #expect(await server.pulls >= 4, "mehrere Durchgänge nötig")
        #expect(try await store.entries(habitId: habit.id,
                                        from: d("2026-08-01"), to: d("2026-08-12")).count == 12)
    }

    @Test("Zweimal abgleichen ohne Änderung tut nichts")
    func secondSyncIsQuiet() async throws {
        let store = try makeStore()
        let server = FakeServer()
        _ = try await store.createHabit(daily())
        let engine = SyncEngine(store: store, transport: server)
        try await engine.sync()

        let zweites = try await engine.sync()
        #expect(zweites.hochgeladen == 0)
        #expect(zweites.uebernommen == 0)
        #expect(zweites.summary == "nichts zu tun")
    }

    @Test("Ein Fehler wird gemeldet und der Cursor bleibt stehen")
    func failureKeepsCursor() async throws {
        let store = try makeStore()
        _ = try await store.createHabit(daily())

        struct Kaputt: SyncTransport {
            func info() async throws -> ServerInfo { throw SyncError.unauthorized }
            func pull(since: Int64, limit: Int) async throws -> SyncDelta {
                throw SyncError.unauthorized
            }
            func push(_ delta: SyncDelta) async throws -> SyncReport {
                throw SyncError.unauthorized
            }
        }

        let engine = SyncEngine(store: store, transport: Kaputt())
        await #expect(throws: SyncError.self) { try await engine.sync() }
        #expect(try await store.syncState().lastServerSeq == 0)
        #expect(try await store.pendingChanges().isEmpty == false, "nichts gilt als übertragen")
        #expect(await engine.letzterFehler != nil)
    }

    /// Die Lücke, durch die der erste Lauf mit der echten App fiel: keiner der
    /// Tests hatte je eine **lokal angelegte** Buchung hochgeladen. Das
    /// Freeze-Konto führt absichtlich kein `updated_at`, und die Quittung
    /// prüfte trotzdem darauf — die Transaktion brach ab und **alles** blieb
    /// offen, obwohl der Server längst alles hatte.
    @Test("Eine lokal verdiente Buchung geht hoch und gilt danach als übertragen")
    func pushesLocalFreeze() async throws {
        let store = try makeStore()
        let server = FakeServer()
        let habit = try await store.createHabit(daily())
        _ = try await store.setBackfillLimitDays(0)

        // Einen durchgezogenen Lauf herstellen, damit das Konto einzahlt.
        let lauf = FocusRun(title: "Woche", startsOn: d("2026-08-25"), endsOn: d("2026-08-27"),
                            habitIds: [habit.id])
        try await store.dbQueue.write { db in var r = try FocusRunRow(lauf); try r.insert(db) }
        for tag in ["2026-08-25", "2026-08-26", "2026-08-27"] {
            try await store.setEntry(habitId: habit.id, date: d(tag), value: 1,
                                     note: nil, source: .manual)
        }
        #expect(try await store.awardPendingFreezes() == 1)
        #expect(try await store.pendingChanges().freezes.count == 1)

        let engine = SyncEngine(store: store, transport: server)
        let ergebnis = try await engine.sync()

        #expect(ergebnis.hochgeladen > 0)
        #expect(try await store.pendingChanges().isEmpty, "nichts darf offen bleiben")
        #expect(try await store.freezeBalance() == 1)
    }

    @Test("Eine Freeze-Buchung wird nur einmal übernommen")
    func freezeIsInsertOnly() async throws {
        let store = try makeStore()
        let server = FakeServer()
        let buchung = FreezeEntry(amount: 1, reason: .focusCompleted, focusRunId: UUID())
        await server.lege(SyncDelta(freezes: [buchung]))

        let engine = SyncEngine(store: store, transport: server)
        try await engine.sync()
        #expect(try await store.freezeBalance() == 1)

        // Dieselbe Buchung noch einmal — der Kontostand darf nicht steigen.
        await server.lege(SyncDelta(freezes: [buchung]))
        try await engine.sync()
        #expect(try await store.freezeBalance() == 1)
    }

    /// Gefunden beim ersten Lauf gegen den echten Server: der Habit wurde vor
    /// seinem Tag angelegt, und `habit_tag` verweist auf ihn — der ganze
    /// Abgleich brach am Fremdschlüssel ab.
    @Test("Ein Habit mit Tag kommt an, egal wie das Delta sortiert ist")
    func tagArrivesBeforeHabit() async throws {
        let store = try makeStore()
        let server = FakeServer()
        let tag = Tag(name: "Gesundheit", colorHex: "#34C759")
        let habit = Habit(name: "Laufen",
                          rules: [HabitRule(effectiveFrom: d("2026-08-01"), schedule: .daily)],
                          tagIds: [tag.id])
        // Bewusst in der ungünstigen Reihenfolge abgelegt.
        await server.lege(SyncDelta(habits: [habit], tags: [tag]))

        let engine = SyncEngine(store: store, transport: server)
        try await engine.sync()

        let geholt = try #require(try await store.listHabits(includeArchived: true).first)
        #expect(geholt.tagIds == [tag.id])
        #expect(try await store.tags().count == 1)
    }

    @Test("Ein unbekannter Tag bricht den Abgleich nicht ab")
    func unknownTagIsSkipped() async throws {
        let store = try makeStore()
        let server = FakeServer()
        // Ein Habit verweist auf einen Tag, den es nirgends gibt.
        let habit = Habit(name: "Laufen",
                          rules: [HabitRule(effectiveFrom: d("2026-08-01"), schedule: .daily)],
                          tagIds: [UUID()])
        await server.lege(SyncDelta(habits: [habit]))

        let engine = SyncEngine(store: store, transport: server)
        try await engine.sync()

        // Der Habit ist da, nur ohne die unmögliche Zuordnung.
        let geholt = try #require(try await store.listHabits(includeArchived: true).first)
        #expect(geholt.name == "Laufen")
        #expect(geholt.tagIds.isEmpty)
    }

    @Test("Das Delta verzeiht fehlende Listen")
    func deltaToleratesMissingLists() throws {
        let json = #"{"entries":[],"nextSeq":7,"hasMore":false}"#
        let delta = try SyncCoding.decoder().decode(SyncDelta.self, from: Data(json.utf8))
        #expect(delta.habits.isEmpty)
        #expect(delta.nextSeq == 7)
    }
}
