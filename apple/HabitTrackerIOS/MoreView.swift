import SwiftUI
import HabitCore
import HabitStore
import HabitUI

/// Alles, was nicht ins tägliche Abhaken gehört.
///
/// Eine Liste von Einstiegen statt weiterer Register: was man selten braucht,
/// soll auffindbar sein und nicht ständig im Weg stehen. Dieselbe Aufteilung
/// wie in der WebApp.
struct MoreView: View {
    @Environment(AppState.self) private var state
    var neuerHabit: () -> Void
    var bearbeiten: (Habit) -> Void

    var body: some View {
        List {
            Section("Habits") {
                NavigationLink {
                    HabitListView(bearbeiten: bearbeiten)
                } label: {
                    Label("Alle Habits", systemImage: "list.bullet")
                        .badge(state.habits.count)
                }
                Button(action: neuerHabit) {
                    Label("Neuer Habit", systemImage: "plus")
                }
            }

            Section("Dieser Tag") {
                Button {
                    state.dayLogEditorDate = state.today
                } label: {
                    Label("Journal", systemImage: "book.closed")
                }
                Button {
                    state.exceptionEditorDate = state.today
                } label: {
                    Label("Ausnahme eintragen", systemImage: "beach.umbrella")
                }
            }

            Section("Verwaltung") {
                NavigationLink { TagsView() } label: {
                    Label("Tags", systemImage: "tag")
                }
                NavigationLink { TrashDestination() } label: {
                    Label("Papierkorb", systemImage: "trash")
                }
                NavigationLink { BackupDestination() } label: {
                    Label("Sicherung", systemImage: "externaldrive")
                }
                NavigationLink { SyncView() } label: {
                    Label("Abgleich", systemImage: "arrow.triangle.2.circlepath")
                        .badge(state.abgleichEingerichtet ? Text("eingerichtet") : nil)
                }
            }
        }
        .navigationTitle("Mehr")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Alle Habits

/// Liste, Reihenfolge, Archiv.
///
/// Verschoben wird über den Bearbeiten-Modus der Liste — auf dem Telefon ist
/// das die Geste, die jeder kennt, und sie funktioniert auch beim Scrollen.
struct HabitListView: View {
    @Environment(AppState.self) private var state
    var bearbeiten: (Habit) -> Void

    var body: some View {
        @Bindable var state = state

        List {
            if state.filteredHabits.isEmpty {
                ContentUnavailableView(
                    "Keine Habits", systemImage: "line.3.horizontal.decrease.circle",
                    description: Text("Mit diesem Filter ist nichts sichtbar."))
            }

            ForEach(state.filteredHabits) { habit in
                NavigationLink {
                    HabitDetailView(habit: habit, onEdit: { bearbeiten(habit) })
                } label: {
                    zeile(habit)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        state.habitPendingDeletion = habit
                    } label: {
                        Label("Löschen", systemImage: "trash")
                    }
                    Button {
                        Task {
                            habit.isArchived ? await state.unarchive(habit)
                                             : await state.archive(habit)
                        }
                    } label: {
                        Label(habit.isArchived ? "Zurückholen" : "Archivieren",
                              systemImage: habit.isArchived ? "tray.and.arrow.up" : "archivebox")
                    }
                    .tint(.orange)
                }
            }
            // Nur ohne Filter: sonst ließe sich die Verschiebung nicht auf die
            // Gesamtreihenfolge übertragen.
            .onMove(perform: state.canReorder
                    ? { quelle, ziel in Task { await state.moveHabits(from: quelle, to: ziel) } }
                    : nil)

            if !state.canReorder && state.filteredHabits.count > 1 {
                Text("Zum Umsortieren den Filter aufheben.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Alle Habits")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    if !state.archivedHabits.isEmpty {
                        Toggle(isOn: $state.showsArchived) {
                            Label("Archiv einblenden", systemImage: "archivebox")
                        }
                    }
                    if !state.tags.isEmpty {
                        Picker("Filter", selection: $state.selectedTagId) {
                            Text("Alle").tag(UUID?.none)
                            ForEach(state.tags) { tag in
                                Text(tag.name).tag(UUID?.some(tag.id))
                            }
                        }
                    }
                } label: {
                    Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
                }
            }
        }
    }

    private func zeile(_ habit: Habit) -> some View {
        let stats = state.stats(habit, from: state.today.adding(days: -400), to: state.today)
        return HStack(spacing: 12) {
            Image(systemName: habit.symbol)
                .foregroundStyle(Color(hex: habit.colorHex))
                .frame(width: 28, height: 28)
                .background(Color(hex: habit.colorHex).opacity(0.15), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(habit.name)
                    if habit.isArchived {
                        Text("archiviert")
                            .font(.caption2).foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
                HStack(spacing: 6) {
                    Text(habit.rule(on: state.today)?.schedule.label ?? "")
                    ForEach(habit.tagIds.compactMap(state.tag)) { TagChip(tag: $0) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if stats.currentStreak > 0 {
                Label("\(stats.currentStreak)", systemImage: "flame.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .opacity(habit.isArchived ? 0.55 : 1)
    }
}
