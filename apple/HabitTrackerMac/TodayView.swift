import SwiftUI
import HabitCore
import HabitUI

/// Die Ansicht, die täglich benutzt wird — deshalb steht hier nur, was heute zählt.
struct TodayView: View {
    @Environment(AppState.self) private var state
    var onEdit: (Habit) -> Void

    var body: some View {
        @Bindable var state = state

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if state.todaysHabits.isEmpty {
                    ContentUnavailableView(
                        "Heute ist nichts fällig",
                        systemImage: "checkmark.circle",
                        description: Text("Für heute ist kein Habit geplant.")
                    )
                    .padding(.top, 40)
                } else {
                    ForEach(groups, id: \.0) { group, habits in
                        section(group, habits)
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("Heute")
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
    }

    // MARK: - Kopf

    private var header: some View {
        let progress = state.todaysProgress
        let share = progress.total == 0 ? 0 : Double(progress.done) / Double(progress.total)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(state.today.longLabel)
                    .font(.title2.weight(.semibold))
                Spacer()
                Text("\(progress.done) von \(progress.total)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: share)
                .tint(share >= 1 ? .green : .accentColor)
        }
    }

    // MARK: - Gruppierung nach Tageszeit

    private var groups: [(String, [Habit])] {
        let habits = state.todaysHabits
        let withTime = TimeOfDay.allCases.compactMap { time -> (String, [Habit])? in
            let matching = habits.filter { $0.timeOfDay == time }
            return matching.isEmpty ? nil : (time.label, matching)
        }
        let withoutTime = habits.filter { $0.timeOfDay == nil }
        // Ohne Tageszeit ans Ende — und ohne eigene Überschrift, wenn es die
        // einzige Gruppe ist, sonst steht dort sinnlos „Sonstige".
        if withoutTime.isEmpty { return withTime }
        if withTime.isEmpty { return [("", withoutTime)] }
        return withTime + [("Ohne feste Zeit", withoutTime)]
    }

    private func section(_ title: String, _ habits: [Habit]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !title.isEmpty {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }
            VStack(spacing: 0) {
                ForEach(habits) { habit in
                    row(habit)
                    if habit.id != habits.last?.id {
                        Divider().padding(.leading, 46)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func row(_ habit: Habit) -> some View {
        HStack(spacing: 8) {
            habitRow(habit)
            HabitMenuButton(
                habit: habit,
                onEdit: { onEdit(habit) },
                onArchive: { Task { await state.archive(habit) } },
                onUnarchive: { Task { await state.unarchive(habit) } },
                onDelete: { state.habitPendingDeletion = habit })
        }
        .contextMenu { actions(habit) }
    }

    private func habitRow(_ habit: Habit) -> some View {
        HabitRowView(
            habit: habit,
            date: state.today,
            status: state.status(habit, on: state.today),
            value: state.value(habit, on: state.today),
            streak: state.stats(habit, from: state.today.adding(days: -400),
                                to: state.today).currentStreak,
            trend: state.trend(habit),
            tags: habit.tagIds.compactMap(state.tag),
            onToggle: { Task { await state.toggle(habit, on: state.today) } },
            onAdjust: { delta in Task { await state.adjust(habit, on: state.today, by: delta) } }
        )
    }

    @ViewBuilder
    private func actions(_ habit: Habit) -> some View {
        HabitActions(
            habit: habit,
            onEdit: { onEdit(habit) },
            onArchive: { Task { await state.archive(habit) } },
            onUnarchive: { Task { await state.unarchive(habit) } },
            onDelete: { state.habitPendingDeletion = habit })
    }
}
