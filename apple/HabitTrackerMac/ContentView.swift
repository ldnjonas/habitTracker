import SwiftUI
import HabitCore
import HabitStore
import HabitUI

struct ContentView: View {
    @Environment(AppState.self) private var state

    @State private var selection: SidebarItem? = .today
    @State private var editing: HabitEditorForm.Mode?
    @State private var trashItems: [TrashItem] = []

    enum SidebarItem: Hashable {
        case today
        case overview
        case focus
        case habits
        case trash
        case backup
        case habit(UUID)
    }

    var body: some View {
        @Bindable var state = state

        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .sheet(item: $editing) { mode in
            HabitEditorForm(
                mode: mode,
                tags: state.tags,
                today: state.today,
                onSave: { draft, patch, rule, tagIds in
                    Task { await save(mode, draft, patch, rule, tagIds) }
                    editing = nil
                },
                onCancel: { editing = nil }
            )
            .frame(minWidth: 480, minHeight: 620)
        }
        .background { todayShortcuts }
        .sheet(item: $state.dayLogEditorDate) { date in
            DayLogEditor(
                date: date,
                existing: state.dayLog(on: date),
                onSave: { log in
                    state.dayLogEditorDate = nil
                    Task { await state.setDayLog(log) }
                },
                onCancel: { state.dayLogEditorDate = nil })
        }
        .sheet(item: $state.exceptionEditorDate) { date in
            ExceptionEditor(
                habits: state.habits,
                today: state.today,
                initialDate: date,
                onSave: { kind, from, to, habitIds, reason in
                    state.exceptionEditorDate = nil
                    Task {
                        await state.addException(kind: kind, from: from, to: to,
                                                 habitIds: habitIds, reason: reason)
                    }
                },
                onCancel: { state.exceptionEditorDate = nil })
        }
        // Eine Rückfrage für alle Stellen, an denen gelöscht werden kann —
        // mehrere Kopien desselben Textes wären mehrere Gelegenheiten, ihn
        // falsch zu pflegen.
        //
        // Als Blatt und nicht als `confirmationDialog`: nur so lässt sich das
        // Symbol des Habits zeigen statt des App-Icons, das dort vom System
        // kommt.
        .sheet(item: $state.habitPendingDeletion) { habit in
            // `habit` stammt aus der Bindung des Blatts und ist beim Auslösen
            // gesetzt — anders als der Zustand, den das Schließen abräumt.
            HabitDeleteConfirmation(
                habit: habit,
                trashWindowDays: state.trashWindowDays,
                onCancel: { state.habitPendingDeletion = nil },
                onDelete: {
                    state.habitPendingDeletion = nil
                    Task { await state.delete(habit) }
                })
        }
        .alert("Fehler", isPresented: .constant(state.errorMessage != nil)) {
            Button("OK") { state.errorMessage = nil }
        } message: {
            Text(state.errorMessage ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: .newHabitRequested)) { _ in
            editing = .create
        }
    }

    // MARK: - Seitenleiste

    private var sidebar: some View {
        List(selection: $selection) {
            Section {
                Label("Heute", systemImage: "sun.max")
                    .badge(openToday)
                    .tag(SidebarItem.today)
                Label("Übersicht", systemImage: "square.grid.3x3")
                    .tag(SidebarItem.overview)
                Label("Fokus", systemImage: "flame")
                    .tag(SidebarItem.focus)
                Label("Alle Habits", systemImage: "list.bullet")
                    .tag(SidebarItem.habits)
            }

            if !state.habits.isEmpty {
                Section("Habits") {
                    ForEach(state.habits) { habit in
                        Label {
                            Text(habit.name)
                        } icon: {
                            Image(systemName: habit.symbol)
                                .foregroundStyle(Color(hex: habit.colorHex))
                        }
                        .tag(SidebarItem.habit(habit.id))
                        // Derselbe Satz Aktionen wie in den Listen und in der
                        // Detail-Toolbar — die Seitenleiste ist für viele der
                        // Ort, an dem sie den Habit vor sich haben.
                        .contextMenu { actions(for: habit) }
                    }
                    // Hier ohne `canReorder`-Prüfung: die Seitenleiste zeigt
                    // immer alle Habits in ihrer Reihenfolge, eine Verschiebung
                    // ist also nie mehrdeutig.
                    .onMove { source, ziel in
                        Task { await state.moveHabits(from: source, to: ziel) }
                    }
                }
            }

            Section {
                Label("Sicherung", systemImage: "externaldrive")
                    .tag(SidebarItem.backup)
                Label("Papierkorb", systemImage: "trash")
                    .tag(SidebarItem.trash)
            }
        }
        .navigationSplitViewColumnWidth(min: 190, ideal: 215)
        .toolbar {
            Button {
                editing = .create
            } label: {
                Label("Neuer Habit", systemImage: "plus")
            }
            .help("Neuen Habit anlegen (⌘N)")
        }
    }

    /// Ziffern 1–9 haken die heutigen Habits ab.
    ///
    /// Hier und nicht in `TodayView`: nur hier ist bekannt, ob gerade ein Blatt
    /// offen ist. Eine blanke Ziffer als Kürzel darf nicht feuern, während
    /// jemand in ein Textfeld tippt.
    @ViewBuilder
    private var todayShortcuts: some View {
        if selection == .today || selection == nil, !isPresentingSheet {
            ForEach(Array(state.todaysHabits.prefix(9).enumerated()), id: \.element.id) { index, habit in
                Button("") { Task { await state.toggle(habit, on: state.today) } }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [])
            }
            // Nicht auf Nullgröße setzen: für einen Knopf ohne Fläche richtet
            // SwiftUI kein Tastenkürzel ein.
            .opacity(0.001)
            .allowsHitTesting(false)
        }
    }

    private var isPresentingSheet: Bool {
        editing != nil
            || state.habitPendingDeletion != nil
            || state.exceptionEditorDate != nil
            || state.dayLogEditorDate != nil
    }

    @ViewBuilder
    private func actions(for habit: Habit) -> some View {
        HabitActions(
            habit: habit,
            onEdit: { editing = .edit(habit) },
            onArchive: { Task { await state.archive(habit) } },
            onUnarchive: { Task { await state.unarchive(habit) } },
            onDelete: { state.habitPendingDeletion = habit })

        // Die Seitenleiste zeigt immer alle Habits — hier ist die Position
        // eindeutig und das Verschieben ohne Vorbehalt möglich.
        if let index = state.habits.firstIndex(of: habit) {
            HabitMoveActions(index: index, count: state.habits.count) { quelle, ziel in
                Task { await state.moveHabits(from: quelle, to: ziel) }
            }
        }
    }

    /// Wie viele der heute fälligen Habits noch offen sind.
    private var openToday: Int {
        let progress = state.todaysProgress
        return progress.total - progress.done
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .today, .none:
            if state.habits.isEmpty && !state.isLoading {
                TemplatePicker(
                    today: state.today,
                    onPick: { draft in Task { await state.createHabit(draft) } },
                    onCreateOwn: { editing = .create }
                )
            } else {
                TodayView(onEdit: { editing = .edit($0) })
            }

        case .overview:
            OverviewView()

        case .focus:
            FocusView()

        case .backup:
            BackupView()

        case .habits:
            HabitListView(
                onEdit: { editing = .edit($0) },
                onSelect: { selection = .habit($0.id) }
            )

        case .habit(let id):
            if let habit = state.habit(id) {
                HabitDetailView(habit: habit, onEdit: { editing = .edit(habit) })
            } else {
                ContentUnavailableView("Habit nicht gefunden", systemImage: "questionmark.circle")
            }

        case .trash:
            TrashView(items: trashItems) { item in
                Task {
                    try? await state.api.restore(item)
                    await state.reload()
                    await loadTrash()
                }
            }
            .task { await loadTrash() }
        }
    }

    private func loadTrash() async {
        trashItems = (try? await state.api.trash()) ?? []
    }

    // MARK: - Sichern

    private func save(
        _ mode: HabitEditorForm.Mode,
        _ draft: HabitDraft,
        _ patch: HabitPatch?,
        _ rule: HabitRule?,
        _ tagIds: [UUID]
    ) async {
        switch mode {
        case .create:
            await state.createHabit(draft)
        case .edit(let habit):
            if let patch { await state.updateHabit(habit.id, patch) }
            if let rule { await state.setRule(habit.id, rule) }
            await state.setTags(habit.id, tagIds)
        }
    }
}

/// Damit `.sheet(item:)` den Bearbeitungsmodus tragen kann.
extension HabitEditorForm.Mode: @retroactive Identifiable {
    public var id: String {
        switch self {
        case .create: "create"
        case .edit(let habit): habit.id.uuidString
        }
    }
}
