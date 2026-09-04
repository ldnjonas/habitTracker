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
    public private(set) var tags: [Tag] = []
    /// Einträge des geladenen Zeitraums, für schnellen Zugriff je Habit und Tag.
    public private(set) var entries: [UUID: [CalendarDate: Entry]] = [:]
    public private(set) var exceptions: [DayException] = []
    public private(set) var isLoading = false

    /// Fehler werden angezeigt, nicht verschluckt — eine Datenbank, die nicht
    /// schreibt, muss man merken.
    public var errorMessage: String?

    public var today: CalendarDate
    /// Filter der Heute- und der Habit-Liste.
    public var selectedTagId: UUID?

    /// Geladener Zeitraum. Ein Jahr rückwärts deckt die Heatmap ab.
    private var loadedFrom: CalendarDate
    private var loadedTo: CalendarDate

    public init(api: any HabitAPI, today: CalendarDate = CalendarDate.today()) {
        self.api = api
        self.today = today
        self.loadedFrom = today.adding(days: -370)
        self.loadedTo = today
    }

    // MARK: - Laden

    public func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            habits = try await api.listHabits(includeArchived: false)
            tags = try await api.tags()
            exceptions = try await api.exceptions(from: loadedFrom, to: loadedTo)

            let all = try await api.entries(habitId: nil, from: loadedFrom, to: loadedTo)
            var grouped: [UUID: [CalendarDate: Entry]] = [:]
            for entry in all {
                grouped[entry.habitId, default: [:]][entry.date] = entry
            }
            entries = grouped
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
        habits
            .filter { selectedTagId.map($0.tagIds.contains) ?? true }
            .sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) }
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

    public func archive(_ habit: Habit) async {
        await updateHabit(habit.id, HabitPatch(archivedOn: .some(today)))
    }

    public func delete(_ habit: Habit) async {
        do {
            try await api.deleteHabit(id: habit.id)
            await reload()
        } catch {
            errorMessage = String(describing: error)
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
