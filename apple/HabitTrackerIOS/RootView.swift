import SwiftUI
import HabitCore
import HabitStore
import HabitUI

/// Das Gerüst: Registerleiste unten, Blätter darüber.
///
/// Dieselben vier Register wie in der WebApp — **Heute · Übersicht · Fokus ·
/// Mehr**. Wer zwischen Browser und App wechselt, soll nicht umlernen müssen;
/// und unten, weil oben der Daumen nicht hinkommt.
///
/// Die Blätter hängen hier und nicht an den einzelnen Ansichten: aus jeder
/// heraus kann ein Habit bearbeitet, ein Tag ins Journal geschrieben oder eine
/// Ausnahme gesetzt werden. Vier Kopien derselben Verdrahtung wären vier
/// Gelegenheiten, sie auseinanderlaufen zu lassen — genau so ist es auf dem Mac
/// in `ContentView` gelöst.
struct RootView: View {
    @Environment(AppState.self) private var state

    @State private var register: Register = .heute
    @State private var editing: HabitEditorForm.Mode?

    enum Register: Hashable { case heute, uebersicht, fokus, mehr }

    var body: some View {
        @Bindable var state = state

        TabView(selection: $register) {
            NavigationStack {
                // Erster Start: Vorlagen statt eines leeren Bildschirms — wie
                // auf dem Mac. Ein neuer Habit ist der einzige sinnvolle
                // nächste Schritt, und ihn erraten zu lassen wäre unfreundlich.
                if state.habits.isEmpty && !state.isLoading {
                    ScrollView {
                        TemplatePicker(
                            today: state.today,
                            onPick: { draft in Task { await state.createHabit(draft) } },
                            onCreateOwn: { editing = .create })
                        .padding(16)
                    }
                    .navigationTitle("Willkommen")
                    .navigationBarTitleDisplayMode(.inline)
                } else {
                    TodayView(bearbeiten: { editing = .edit($0) })
                }
            }
            .tabItem { Label("Heute", systemImage: "sun.max") }
            .badge(offenHeute)
            .tag(Register.heute)

            NavigationStack {
                OverviewView()
            }
            .tabItem { Label("Übersicht", systemImage: "square.grid.3x3") }
            .tag(Register.uebersicht)

            NavigationStack {
                FocusView()
            }
            .tabItem { Label("Fokus", systemImage: "flame") }
            .tag(Register.fokus)

            NavigationStack {
                MoreView(neuerHabit: { editing = .create },
                         bearbeiten: { editing = .edit($0) })
            }
            .tabItem { Label("Mehr", systemImage: "ellipsis") }
            .tag(Register.mehr)
        }
        .sheet(item: $editing) { mode in
            NavigationStack {
                HabitEditorForm(
                    mode: mode,
                    tags: state.tags,
                    today: state.today,
                    onSave: { draft, patch, rule, tagIds in
                        Task { await save(mode, draft, patch, rule, tagIds) }
                        editing = nil
                    },
                    onCancel: { editing = nil })
            }
        }
        .sheet(item: $state.dayLogEditorDate) { date in
            NavigationStack {
                DayLogEditor(
                    date: date,
                    existing: state.dayLog(on: date),
                    onSave: { log in
                        state.dayLogEditorDate = nil
                        Task { await state.setDayLog(log) }
                    },
                    onCancel: { state.dayLogEditorDate = nil })
            }
        }
        .sheet(item: $state.exceptionEditorDate) { date in
            NavigationStack {
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
        }
        // Eine Rückfrage für alle Stellen, an denen gelöscht werden kann. Als
        // Blatt und nicht als `confirmationDialog`: nur so lässt sich das
        // Symbol des Habits zeigen statt des App-Icons, das dort vom System
        // kommt.
        .sheet(item: $state.habitPendingDeletion) { habit in
            HabitDeleteConfirmation(
                habit: habit,
                trashWindowDays: state.trashWindowDays,
                onCancel: { state.habitPendingDeletion = nil },
                onDelete: {
                    state.habitPendingDeletion = nil
                    Task { await state.delete(habit) }
                })
            .presentationDetents([.medium])
        }
        .alert("Fehler", isPresented: .constant(state.errorMessage != nil)) {
            Button("OK") { state.errorMessage = nil }
        } message: {
            Text(state.errorMessage ?? "")
        }
    }

    /// Wie viele heute noch offen sind — als Zahl am Register.
    private var offenHeute: Int {
        let fortschritt = state.todaysProgress
        return max(0, fortschritt.total - fortschritt.done)
    }

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
