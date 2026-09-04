import SwiftUI
import HabitCore
import HabitUI

/// Verwaltungsansicht: alles, was nicht ins tägliche Abhaken gehört.
struct HabitListView: View {
    @Environment(AppState.self) private var state
    var onEdit: (Habit) -> Void
    var onSelect: (Habit) -> Void

    var body: some View {
        @Bindable var state = state

        List {
            ForEach(state.filteredHabits) { habit in
                row(habit)
                    .contentShape(Rectangle())
                    .onTapGesture { onSelect(habit) }
                    .contextMenu {
                        Button("Bearbeiten …") { onEdit(habit) }
                        Button("Archivieren") { Task { await state.archive(habit) } }
                        Divider()
                        Button("Löschen", role: .destructive) { Task { await state.delete(habit) } }
                    }
            }
        }
        .navigationTitle("Alle Habits")
        .toolbar {
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
                Text(habit.name)
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
        }
        .padding(.vertical, 3)
    }
}
