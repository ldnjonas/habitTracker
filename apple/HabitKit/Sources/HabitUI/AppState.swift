import SwiftUI
import HabitCore
import HabitStore

/// Beobachtbarer Zustand für alle Views.
///
/// Hält die `HabitAPI` und einen Ausschnitt der Daten im Speicher. Die Views
/// kennen nur diesen Typ und das Protokoll — wenn später die `SyncEngine`
/// dazukommt, ändert sich hier nichts, weil weiterhin die lokale Datenbank
/// gelesen wird.
@MainActor
@Observable
public final class AppState {
    public let api: any HabitAPI

    public private(set) var habits: [Habit] = []
    /// Getrennt gehalten: archivierte Habits sollen nirgends mitzählen, wo
    /// `habits` benutzt wird — aber erreichbar bleiben. Ohne einen Weg zurück
    /// wäre Archivieren eine Falle.
    public private(set) var archivedHabits: [Habit] = []
    public private(set) var tags: [Tag] = []
    /// Einträge des geladenen Zeitraums, für schnellen Zugriff je Habit und Tag.
    public private(set) var entries: [UUID: [CalendarDate: Entry]] = [:]
    public private(set) var exceptions: [DayException] = []
    public private(set) var focusRuns: [FocusRun] = []
    /// Verfügbare Streak Freezes.
    public private(set) var freezeBalance: Int = 0
    public private(set) var isLoading = false

    /// Fehler werden angezeigt, nicht verschluckt — eine Datenbank, die nicht
    /// schreibt, muss man merken.
    public var errorMessage: String?

    public var today: CalendarDate
    /// Filter der Heute- und der Habit-Liste.
    public var selectedTagId: UUID?
    /// Ob „Alle Habits" auch das Archiv zeigt.
    public var showsArchived = false
    /// Der Habit, für den die Löschrückfrage offen ist.
    public var habitPendingDeletion: Habit?
    /// Der Tag, für den das Ausnahme-Blatt offen ist.
    public var exceptionEditorDate: CalendarDate?

    /// Geladener Zeitraum. Ein Jahr rückwärts deckt die Heatmap ab.
    private var loadedFrom: CalendarDate
    private var loadedTo: CalendarDate

    public init(api: any HabitAPI, today: CalendarDate = CalendarDate.today()) {
        self.api = api
        self.today = today
        self.overviewAnchor = today
        self.loadedFrom = today.adding(days: -370)
        self.loadedTo = today
    }

    // MARK: - Laden

    /// Zieht den Stichtag nach, wenn inzwischen ein neuer Tag begonnen hat.
    ///
    /// Ohne das zeigt eine App, die über Nacht in der Menüleiste hängt, am
    /// Morgen noch die Liste von gestern — samt Häkchen, die nicht mehr gelten.
    /// Der Zeitraum wandert mit, sonst fehlten die Einträge des neuen Tages.
    ///
    /// Gibt zurück, ob sich etwas geändert hat.
    @discardableResult
    public func refreshToday() async -> Bool {
        let jetzt = CalendarDate.today()
        guard jetzt != today else { return false }
        today = jetzt
        overviewAnchor = jetzt
        loadedTo = max(loadedTo, jetzt)
        await reload()
        return true
    }

    public func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            // Eine Abfrage für beides; die Trennung passiert hier.
            let loaded = try await api.listHabits(includeArchived: true)
            habits = loaded.filter { !$0.isArchived }
            archivedHabits = loaded.filter(\.isArchived)
            tags = try await api.tags()
            focusRuns = try await api.focusRuns()

            // Das geladene Fenster muss jeden Fokus-Lauf abdecken. Sonst
            // rechnete ein alter Lauf mangels Einträgen als gescheitert — und
            // ein Verlauf, der Erfolge in Misserfolge verwandelt, ist schlimmer
            // als keiner.
            if let earliest = focusRuns.map(\.startsOn).min() {
                loadedFrom = min(loadedFrom, earliest)
            }
            exceptions = try await api.exceptions(from: loadedFrom, to: loadedTo)

            let all = try await api.entries(habitId: nil, from: loadedFrom, to: loadedTo)
            var grouped: [UUID: [CalendarDate: Entry]] = [:]
            for entry in all {
                grouped[entry.habitId, default: [:]][entry.date] = entry
            }
            entries = grouped
            refreshColorReference()

            // Beim Nachladen mitbuchen, was durchgezogene Läufe verdient haben.
            // Idempotent über die Lauf-id — sonst hinkte der Kontostand
            // hinterher, bis jemand zufällig den Fokus-Tab öffnet.
            try await api.awardPendingFreezes()
            freezeBalance = try await api.freezeBalance()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    // MARK: - Abfragen

    public func entry(_ habit: Habit, on date: CalendarDate) -> Entry? {
        entries[habit.id]?[date]
    }

    public func value(_ habit: Habit, on date: CalendarDate) -> Double {
        entry(habit, on: date)?.value ?? 0
    }

    public func exception(_ habit: Habit, on date: CalendarDate) -> DayException? {
        // Eine habit-spezifische Ausnahme ist die genauere Aussage als eine globale.
        let candidates = exceptions.filter {
            $0.date == date && ($0.habitId == nil || $0.habitId == habit.id)
        }
        return candidates.first { $0.habitId != nil } ?? candidates.first
    }

    public func status(_ habit: Habit, on date: CalendarDate) -> DayStatus {
        HabitCore.status(for: habit, entry: entry(habit, on: date),
                         exception: exception(habit, on: date), on: date, today: today)
    }

    /// Habits, die heute zur Debatte stehen — gefiltert, sortiert und nach
    /// Tageszeit gruppiert.
    public var todaysHabits: [Habit] {
        habits
            .filter { $0.isScheduled(on: today) }
            .filter { selectedTagId.map($0.tagIds.contains) ?? true }
            .sorted {
                // Ohne Tageszeit ans Ende, sonst nach Tagesabschnitt und Reihenfolge.
                let a = $0.timeOfDay, b = $1.timeOfDay
                if a != b {
                    guard let a else { return false }
                    guard let b else { return true }
                    return a < b
                }
                if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
                return $0.name < $1.name
            }
    }

    public var filteredHabits: [Habit] {
        (showsArchived ? habits + archivedHabits : habits)
            .filter { selectedTagId.map($0.tagIds.contains) ?? true }
            .sorted {
                // Archiviertes ans Ende, sonst nach Reihenfolge und Namen.
                if $0.isArchived != $1.isArchived { return !$0.isArchived }
                return ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name)
            }
    }

    /// Sucht einen Habit, auch im Archiv.
    public func habit(_ id: UUID) -> Habit? {
        habits.first { $0.id == id } ?? archivedHabits.first { $0.id == id }
    }

    public func tag(_ id: UUID) -> Tag? { tags.first { $0.id == id } }

    /// Wie viele der heute fälligen Habits erledigt sind.
    public var todaysProgress: (done: Int, total: Int) {
        let due = todaysHabits
        return (due.filter { status($0, on: today).isCompleted }.count, due.count)
    }

    public func stats(_ habit: Habit, from: CalendarDate, to: CalendarDate) -> HabitStats {
        let list = Array(entries[habit.id]?.values ?? [:].values)
        return HabitCore.stats(for: habit, entries: list, exceptions: exceptions,
                               from: from, to: to, today: today)
    }

    // MARK: - Gesamtübersicht

    /// Woche, Monat oder Jahr.
    public var overviewSpan: OverviewSpan = .year
    /// Der Tag, um den herum der Ausschnitt liegt. Blättern verschiebt ihn.
    public var overviewAnchor: CalendarDate

    /// Der gezeigte Zeitraum.
    ///
    /// Die Kennzahlen darüber beziehen sich auf genau dieses Fenster — eine Zahl,
    /// die einen anderen Zeitraum meint als das Bild darunter, wäre irreführend.
    public var overviewRange: (from: CalendarDate, to: CalendarDate) {
        overviewSpan.range(containing: overviewAnchor)
    }

    /// Ob es vorwärts noch etwas zu sehen gibt.
    public var canStepOverviewForward: Bool { overviewRange.to < today }

    public func stepOverview(by steps: Int) async {
        overviewAnchor = overviewSpan.shift(overviewAnchor, by: steps)
        await ensureOverviewLoaded()
    }

    public func resetOverviewToToday() async {
        overviewAnchor = today
        await ensureOverviewLoaded()
    }

    /// Holt Einträge nach, wenn der gewählte Ausschnitt außerhalb des bereits
    /// geladenen Fensters liegt.
    ///
    /// Beim Blättern in weit zurückliegende Monate wäre die Ansicht sonst leer,
    /// obwohl Daten vorhanden sind — ein Fehler, den man für „da war nichts“ hält.
    public func ensureOverviewLoaded() async {
        let range = overviewRange
        guard range.from < loadedFrom || range.to > loadedTo else { return }
        loadedFrom = min(loadedFrom, range.from)
        loadedTo = max(loadedTo, range.to)
        await reload()
    }

    /// Alle Habits je Tag zusammengefasst.
    ///
    /// Bewusst berechnet statt zwischengespeichert: rund 370 Tage mal eine
    /// Handvoll Habits sind einige tausend Vergleiche und damit weit unter einer
    /// Millisekunde. Ein Zwischenspeicher müsste bei jedem Abhaken, jeder
    /// Ausnahme und jeder Zeitplanänderung verworfen werden — die Gelegenheit,
    /// das einmal zu vergessen, kostet mehr als die Rechnung.
    public var overviewSummaries: [CalendarDate: DaySummary] {
        let range = overviewRange
        return HabitCore.overview(habits: habits, entries: allEntries,
                                  exceptions: exceptions,
                                  from: range.from, to: range.to, today: today)
    }

    /// Bezugsgröße der Farbskala: die höchste Zahl an Erledigungen an einem Tag
    /// der letzten zwölf Monate.
    ///
    /// Bewusst über den ganzen Zeitraum und nicht über den gezeigten Ausschnitt:
    /// sonst bedeutete dasselbe Blau in der Wochenansicht etwas anderes als in
    /// der Jahresansicht, und ein Blättern zurück färbte eine magere Woche
    /// plötzlich kräftig ein.
    public private(set) var colorReference: Int = 0

    private func refreshColorReference() {
        let from = today.weekStart.adding(days: -7 * 52)
        let summaries = HabitCore.overview(habits: habits, entries: allEntries,
                                           exceptions: exceptions,
                                           from: from, to: today, today: today)
        colorReference = summaries.values.map(\.completed).max() ?? 0
    }

    public var overviewStats: OverviewStats {
        let range = overviewRange
        return HabitCore.overviewStats(summaries: overviewSummaries,
                                       from: range.from, to: range.to, today: today)
    }

    private var allEntries: [Entry] {
        entries.values.flatMap(\.values)
    }

    // MARK: - Fokus

    /// Alle Läufe ausgewertet, der jüngste zuerst.
    ///
    /// Berechnet statt über den Store geholt: `evaluate` ist eine reine
    /// Funktion über Daten, die ohnehin im Speicher liegen. Über den Store
    /// kostete jedes Abhaken drei zusätzliche Abfragen, nur damit der Banner
    /// im Kopf der Übersicht mitzählt.
    public var focusProgress: [FocusProgress] {
        focusRuns.map {
            HabitCore.evaluate($0, habits: habits, entries: allEntries,
                               exceptions: exceptions, today: today)
        }
    }

    /// Der laufende oder anstehende Fokus, falls es einen gibt.
    public var activeFocus: FocusProgress? {
        focusProgress.first { $0.outcome.isOpen }
    }

    public var focusRecord: FocusRecord {
        record(of: focusProgress.map(\.outcome))
    }

    public func startFocus(days: Int, habitIds: [UUID], title: String?) async {
        do {
            _ = try await api.startFocus(days: days, habitIds: habitIds, title: title)
            await reload()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func abandonFocus(_ id: UUID) async {
        do {
            try await api.abandonFocus(id: id)
            await reload()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func deleteFocusRun(_ id: UUID) async {
        do {
            try await api.deleteFocusRun(id: id)
            await reload()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    /// Was an einem Tag anstand und was daraus wurde — für die Detailzeile
    /// unter der Übersichts-Heatmap.
    ///
    /// Enthält, was an dem Tag verpflichtend war, und zusätzlich alles
    /// Erledigte: ein freiwillig erledigter Wochen-Habit gehört ins Bild, ein
    /// nicht erledigter nicht.
    public func dayBreakdown(on date: CalendarDate) -> [(habit: Habit, status: DayStatus)] {
        habits.compactMap { habit in
            let dayStatus = status(habit, on: date)
            guard dayStatus.isCompleted || habit.isRequired(on: date) else { return nil }
            return (habit, dayStatus)
        }
        .sorted {
            // Erledigtes zuerst, danach alphabetisch — die Liste soll die gute
            // Nachricht oben haben.
            if $0.status.isCompleted != $1.status.isCompleted { return $0.status.isCompleted }
            return $0.habit.name < $1.habit.name
        }
    }

    public func trend(_ habit: Habit) -> Trend? {
        let list = Array(entries[habit.id]?.values ?? [:].values)
        return HabitCore.trend(for: habit, entries: list, exceptions: exceptions, today: today)
    }

    // MARK: - Schreiben

    /// Hakt ab oder nimmt zurück, je nach aktuellem Zustand.
    public func toggle(_ habit: Habit, on date: CalendarDate) async {
        let done = status(habit, on: date).isCompleted
        switch habit.kind {
        case .binary:
            await setValue(habit, on: date, to: done ? 0 : 1)
        case .avoid:
            // Bei Vermeidung ist „erfüllt" der Normalzustand; der Knopf meldet
            // einen Verstoß, statt etwas abzuhaken.
            await setValue(habit, on: date, to: done ? 1 : 0)
        case .quantity:
            let target = habit.target(on: date)?.value ?? 1
            await setValue(habit, on: date, to: done ? 0 : target)
        }
    }

    public func setValue(_ habit: Habit, on date: CalendarDate, to value: Double) async {
        do {
            if value == 0 && habit.kind != .avoid {
                try await api.deleteEntry(habitId: habit.id, date: date)
                entries[habit.id]?[date] = nil
            } else {
                let saved = try await api.setEntry(habitId: habit.id, date: date,
                                                   value: value, note: nil, source: .manual)
                entries[habit.id, default: [:]][date] = saved
            }
            // Ein neuer Tagesrekord verschiebt den Maßstab der Farbskala.
            refreshColorReference()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func adjust(_ habit: Habit, on date: CalendarDate, by delta: Double) async {
        await setValue(habit, on: date, to: max(0, value(habit, on: date) + delta))
    }

    public func createHabit(_ draft: HabitDraft) async {
        do {
            _ = try await api.createHabit(draft)
            await reload()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func updateHabit(_ id: UUID, _ patch: HabitPatch) async {
        do {
            _ = try await api.updateHabit(id: id, patch)
            await reload()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func setRule(_ habitId: UUID, _ rule: HabitRule) async {
        do {
            _ = try await api.setRule(habitId: habitId, rule)
            await reload()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func setTags(_ habitId: UUID, _ tagIds: [UUID]) async {
        do {
            _ = try await api.setTags(habitId: habitId, tagIds: tagIds)
            await reload()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    // MARK: - Freezes

    /// Ob dieser Tag für diesen Habit einfrierbar ist — und Guthaben da ist.
    public func canFreeze(_ habit: Habit, on date: CalendarDate) -> Bool {
        freezeBalance > 0
            && HabitCore.canFreeze(status(habit, on: date), on: date, today: today)
    }

    public func applyFreeze(_ habit: Habit, on date: CalendarDate) async {
        do {
            _ = try await api.applyFreeze(habitId: habit.id, date: date)
            await reload()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    // MARK: - Sitzungen

    /// Trägt eine Sitzung ein. Der Tag ergibt sich aus dem Start — eine Sitzung
    /// über Mitternacht gehört zu dem Tag, an dem sie begonnen hat.
    public func addSession(habitId: UUID, start: Date, end: Date) async {
        do {
            _ = try await api.setEvent(EntryEvent(
                habitId: habitId, date: CalendarDate(start),
                at: start, endsAt: end, value: 0))
            await reload()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func deleteSession(habitId: UUID, eventId: UUID) async {
        do {
            try await api.deleteEvent(habitId: habitId, eventId: eventId)
            await reload()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func periodTotal(_ habit: Habit,
                            from: CalendarDate, to: CalendarDate) -> PeriodTotal {
        HabitCore.periodTotal(for: habit, entries: allEntries, from: from, to: to)
    }

    // MARK: - Ausnahmen

    /// Trägt eine Ausnahme für einen Zeitraum ein.
    ///
    /// Je Tag eine Zeile: die Domäne wertet Tag für Tag aus, und ein
    /// gespeicherter Zeitraum müsste beim Lesen ohnehin wieder in Tage zerlegt
    /// werden. `habitIds` leer heißt global — dann trägt die Zeile
    /// `habitId == nil` und gilt auch für später angelegte Habits.
    public func addException(
        kind: ExceptionKind,
        from: CalendarDate,
        to: CalendarDate,
        habitIds: [UUID] = [],
        reason: String? = nil
    ) async {
        do {
            for date in from.through(to) {
                if habitIds.isEmpty {
                    _ = try await api.addException(
                        DayException(habitId: nil, date: date, kind: kind, reason: reason))
                } else {
                    for habitId in habitIds {
                        _ = try await api.addException(
                            DayException(habitId: habitId, date: date,
                                         kind: kind, reason: reason))
                    }
                }
            }
            await reload()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    /// Nimmt Ausnahmen eines Tages zurück.
    ///
    /// `habitId == nil` entfernt alle an diesem Tag, auch die globale — sonst
    /// bliebe nach dem Aufheben eines Urlaubs eine unsichtbare Zeile stehen,
    /// die den Tag weiterhin aus der Statistik nimmt.
    public func removeExceptions(on date: CalendarDate, habitId: UUID? = nil) async {
        let betroffen = exceptions.filter {
            $0.date == date && (habitId == nil || $0.habitId == habitId || $0.habitId == nil)
        }
        guard !betroffen.isEmpty else { return }
        do {
            for exception in betroffen {
                try await api.deleteException(id: exception.id)
            }
            await reload()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    /// Alle Ausnahmen eines Tages — für die Anzeige im Tagesdetail.
    public func exceptions(on date: CalendarDate) -> [DayException] {
        exceptions.filter { $0.date == date }
    }

    /// Je Tag eine Art, für die Raster der Übersicht.
    ///
    /// Liegen an einem Tag mehrere vor, gewinnt die weitreichendste: Urlaub sagt
    /// mehr über den Tag aus als ein einzelner Ruhetag, und ein Freeze ist die
    /// engste Aussage von allen.
    public var exceptionKindsByDay: [CalendarDate: ExceptionKind] {
        var result: [CalendarDate: ExceptionKind] = [:]
        let rank: [ExceptionKind: Int] = [.paused: 3, .skipped: 2, .frozen: 1]
        for exception in exceptions {
            let vorhanden = result[exception.date]
            if vorhanden == nil || rank[exception.kind, default: 0] > rank[vorhanden!, default: 0] {
                result[exception.date] = exception.kind
            }
        }
        return result
    }

    public func archive(_ habit: Habit) async {
        await updateHabit(habit.id, HabitPatch(archivedOn: .some(today)))
    }

    public func unarchive(_ habit: Habit) async {
        await updateHabit(habit.id, HabitPatch(archivedOn: .some(nil)))
    }

    /// Wie lange Gelöschtes zurückholbar bleibt — für den Text der Rückfrage.
    public var trashWindowDays: Int { LocalHabitAPI.trashWindowDays }

    public func delete(_ habit: Habit) async {
        do {
            try await api.deleteHabit(id: habit.id)
            await reload()
        } catch {
            errorMessage = String(describing: error)
        }
    }


    // MARK: - Sicherung

    /// `habitIds == nil` sichert alles.
    public func exportBackup(habitIds: Set<UUID>? = nil) async -> BackupFile? {
        do {
            return try await api.exportBackup(habitIds: habitIds,
                                              generator: LocalHabitAPI.defaultGenerator)
        } catch {
            errorMessage = String(describing: error)
            return nil
        }
    }

    public func importBackup(_ file: BackupFile, mode: ImportMode) async -> ImportReport? {
        do {
            let report = try await api.importBackup(file, mode: mode)
            await reload()
            return report
        } catch {
            errorMessage = String(describing: error)
            return nil
        }
    }

    public func createTag(name: String, colorHex: String) async {
        do {
            _ = try await api.createTag(name: name, colorHex: colorHex)
            await reload()
        } catch {
            errorMessage = String(describing: error)
        }
    }
}
