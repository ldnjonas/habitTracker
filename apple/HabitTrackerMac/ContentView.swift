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
        // Eine Rückfrage für alle drei Stellen, an denen gelöscht werden kann —
        // drei Kopien desselben Textes wären drei Gelegenheiten, ihn falsch zu
        // pflegen.
        .confirmationDialog(
            "„\(state.habitPendingDeletion?.name ?? "")“ löschen?",
            // Echte Zwei-Wege-Bindung statt `.constant`: schließt der Dialog
            // auf anderem Weg, muss der Zustand mitgehen — sonst erschiene er
            // sofort wieder.
            isPresented: Binding(get: { state.habitPendingDeletion != nil },
                                 set: { if !$0 { state.habitPendingDeletion = nil } }),
            presenting: state.habitPendingDeletion
        ) { _ in
            Button("Löschen", role: .destructive) {
                Task { await state.confirmPendingDeletion() }
            }
            Button("Abbrechen", role: .cancel) { state.habitPendingDeletion = nil }
        } message: { _ in
            Text("Der Habit und sein gesamter Verlauf liegen \(state.trashWindowDays) Tage im Papierkorb und lassen sich von dort zurückholen.")
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

    @ViewBuilder
    private func actions(for habit: Habit) -> some View {
        HabitActions(
            habit: habit,
            onEdit: { editing = .edit(habit) },
            onArchive: { Task { await state.archive(habit) } },
            onUnarchive: { Task { await state.unarchive(habit) } },
            onDelete: { state.habitPendingDeletion = habit })
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
