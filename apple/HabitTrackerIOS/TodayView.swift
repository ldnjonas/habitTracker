import SwiftUI
import HabitCore
import HabitUI

/// Die Ansicht, die täglich benutzt wird — deshalb steht hier nur, was heute zählt.
///
/// Wie auf dem Mac, mit zwei Unterschieden, die vom Gerät kommen: statt
/// Rechtsklick wischt man, und statt der Ziffern 1–9 tippt man. Die Zeile
/// selbst ist dieselbe (`HabitRowView`) — sie kennt keine Plattform.
struct TodayView: View {
    @Environment(AppState.self) private var state
    var bearbeiten: (Habit) -> Void

    var body: some View {
        @Bindable var state = state

        List {
            Section {
                kopf
                    .listRowInsets(EdgeInsets(top: 6, leading: 4, bottom: 10, trailing: 4))
                    .listRowSeparator(.hidden)
            }

            if state.todaysHabits.isEmpty {
                Section {
                    ContentUnavailableView(
                        "Heute ist nichts fällig",
                        systemImage: "checkmark.circle",
                        description: Text("Für heute ist kein Habit geplant."))
                }
            } else {
                ForEach(gruppen, id: \.0) { titel, habits in
                    Section(titel) {
                        ForEach(habits) { habit in
                            zeile(habit)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Heute")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await state.reload() }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if !state.tags.isEmpty {
                    Menu {
                        Picker("Filter", selection: $state.selectedTagId) {
                            Text("Alle").tag(UUID?.none)
                            ForEach(state.tags) { tag in
                                Text(tag.name).tag(UUID?.some(tag.id))
                            }
                        }
                    } label: {
                        Label("Filter", systemImage: state.selectedTagId == nil
                              ? "line.3.horizontal.decrease.circle"
                              : "line.3.horizontal.decrease.circle.fill")
                    }
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    state.dayLogEditorDate = state.today
                } label: {
                    Label("Journal", systemImage: "book.closed")
                }
                Button {
                    state.exceptionEditorDate = state.today
                } label: {
                    Label("Ausnahme", systemImage: "beach.umbrella")
                }
            }
        }
    }

    // MARK: - Kopf

    private var kopf: some View {
        let fortschritt = state.todaysProgress
        let anteil = fortschritt.total == 0
            ? 0 : Double(fortschritt.done) / Double(fortschritt.total)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(state.today.longLabel)
                    .font(.title3.weight(.semibold))
                Spacer()
                Text("\(fortschritt.done) von \(fortschritt.total)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: anteil)
                .tint(anteil >= 1 ? .green : .accentColor)
        }
    }

    // MARK: - Gruppierung nach Tageszeit

    private var gruppen: [(String, [Habit])] {
        let habits = state.todaysHabits
        let mitZeit = TimeOfDay.allCases.compactMap { zeit -> (String, [Habit])? in
            let passende = habits.filter { $0.timeOfDay == zeit }
            return passende.isEmpty ? nil : (zeit.label, passende)
        }
        let ohneZeit = habits.filter { $0.timeOfDay == nil }
        // Ohne Tageszeit ans Ende — und ohne eigene Überschrift, wenn es die
        // einzige Gruppe ist, sonst steht dort sinnlos „Ohne feste Zeit".
        if ohneZeit.isEmpty { return mitZeit }
        if mitZeit.isEmpty { return [("", ohneZeit)] }
        return mitZeit + [("Ohne feste Zeit", ohneZeit)]
    }

    private func zeile(_ habit: Habit) -> some View {
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
            onAdjust: { delta in Task { await state.adjust(habit, on: state.today, by: delta) } })
        // Wischen statt Rechtsklick: auf dem Telefon ist das die Geste, mit der
        // man eine Zeile befragt.
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                state.habitPendingDeletion = habit
            } label: {
                Label("Löschen", systemImage: "trash")
            }
            Button {
                Task { await state.archive(habit) }
            } label: {
                Label("Archivieren", systemImage: "archivebox")
            }
            .tint(.orange)
        }
        .swipeActions(edge: .leading) {
            Button {
                bearbeiten(habit)
            } label: {
                Label("Bearbeiten", systemImage: "pencil")
            }
            .tint(.accentColor)
        }
    }
}
