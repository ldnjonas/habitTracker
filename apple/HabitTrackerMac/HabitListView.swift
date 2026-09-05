import SwiftUI
import HabitCore
import HabitUI

/// Verwaltungsansicht: alles, was nicht ins tägliche Abhaken gehört.
struct HabitListView: View {
    @Environment(AppState.self) private var state
    var onEdit: (Habit) -> Void
    var onSelect: (Habit) -> Void

    @State private var selection: UUID?

    var body: some View {
        @Bindable var state = state

        // `List(selection:)` statt einer eigenen Tippgeste auf der Zeile: eine
        // solche Geste fängt auf dem Mac das Ziehen ab, bevor die Liste es
        // sieht — dann lässt sich trotz `.onMove` nichts verschieben. Wer die
        // Auswahl der Liste überlässt, bekommt Klicken und Ziehen beides.
        List(selection: $selection) {
            ForEach(state.filteredHabits) { habit in
                row(habit)
                    .tag(habit.id)
                    .contextMenu { actions(habit) }
            }
            // Nur ohne Filter: sonst ließe sich die Verschiebung nicht auf die
            // Gesamtreihenfolge übertragen.
            .onMove(perform: state.canReorder
                    ? { source, ziel in Task { await state.moveHabits(from: source, to: ziel) } }
                    : nil)

            if !state.canReorder && state.filteredHabits.count > 1 {
                Text("Zum Umsortieren den Filter aufheben.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onChange(of: selection) { _, neu in
            guard let neu, let habit = state.habit(neu) else { return }
            // Zurücksetzen, sonst öffnet dieselbe Zeile beim zweiten Anklicken
            // nicht mehr — die Auswahl hätte sich ja nicht geändert.
            selection = nil
            onSelect(habit)
        }
        .navigationTitle("Alle Habits")
        .toolbar {
            if !state.archivedHabits.isEmpty {
                Toggle(isOn: $state.showsArchived) {
                    Label("Archiv", systemImage: "archivebox")
                }
                .help("Archivierte Habits einblenden")
            }
            if !state.tags.isEmpty {
                Picker("Filter", selection: $state.selectedTagId) {
                    Text("Alle").tag(UUID?.none)
                    ForEach(state.tags) { tag in
                        Text(tag.name).tag(UUID?.some(tag.id))
                    }
                }
            }
        }
        .overlay {
            if state.filteredHabits.isEmpty {
                ContentUnavailableView("Keine Habits",
                                       systemImage: "line.3.horizontal.decrease.circle",
                                       description: Text("Mit diesem Filter ist nichts sichtbar."))
            }
        }
    }

    private func row(_ habit: Habit) -> some View {
        let stats = state.stats(habit, from: state.today.adding(days: -400), to: state.today)
        return HStack(spacing: 12) {
            Image(systemName: habit.symbol)
                .foregroundStyle(Color(hex: habit.colorHex))
                .frame(width: 26, height: 26)
                .background(Color(hex: habit.colorHex).opacity(0.15), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(habit.name)
                    if habit.isArchived {
                        Text("archiviert")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
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
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Text(percent(stats.completionRate))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)

            HabitMenuButton(
                habit: habit,
                onEdit: { onEdit(habit) },
                onArchive: { Task { await state.archive(habit) } },
                onUnarchive: { Task { await state.unarchive(habit) } },
                onDelete: { state.habitPendingDeletion = habit })
        }
        .padding(.vertical, 3)
        .opacity(habit.isArchived ? 0.55 : 1)
    }

    @ViewBuilder
    private func actions(_ habit: Habit) -> some View {
        HabitActions(
            habit: habit,
            onEdit: { onEdit(habit) },
            onArchive: { Task { await state.archive(habit) } },
            onUnarchive: { Task { await state.unarchive(habit) } },
            onDelete: { state.habitPendingDeletion = habit })

        // Verschieben auch ohne Ziehen. Eine Reihenfolge, die nur per Drag
        // erreichbar ist, ist für Tastaturnutzer keine — und wenn das Ziehen
        // klemmt, ist sie für alle keine.
        if state.canReorder, let index = state.filteredHabits.firstIndex(of: habit) {
            Divider()
            Button {
                Task { await state.moveHabits(from: IndexSet(integer: index), to: index - 1) }
            } label: {
                Label("Nach oben", systemImage: "arrow.up")
            }
            .disabled(index == 0)

            Button {
                // `move` rechnet das Ziel vor dem Entfernen — eine Position
                // tiefer ist deshalb index + 2, nicht index + 1.
                Task { await state.moveHabits(from: IndexSet(integer: index), to: index + 2) }
            } label: {
                Label("Nach unten", systemImage: "arrow.down")
            }
            .disabled(index == state.filteredHabits.count - 1)
        }
    }
}
