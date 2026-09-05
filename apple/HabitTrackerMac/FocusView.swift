import SwiftUI
import HabitCore
import HabitUI

/// Fokus-Läufe: der laufende, das Startformular und der Verlauf.
///
/// Der Streak fragt „wie lange schon?", der Fokus fragt „schaffe ich *diese*
/// Woche?". Ein Streak, der bei 40 steht, ist kaum noch zu gewinnen — nur zu
/// verlieren. Ein Fokus lässt sich gewinnen, und zwar bald.
struct FocusView: View {
    @Environment(AppState.self) private var state

    @State private var days = 7
    @State private var title = ""
    @State private var scopeIsSelection = false
    @State private var selection: Set<UUID> = []
    @State private var runToDelete: FocusRun?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                let progress = state.focusProgress

                if !progress.isEmpty {
                    FocusRecordRow(record: state.focusRecord)
                        .padding(.bottom, 2)
                }

                if let active = state.activeFocus {
                    FocusBanner(progress: active, today: state.today,
                                habitNames: habitNames(active.run)) {
                        Task { await state.abandonFocus(active.run.id) }
                    }
                } else {
                    startCard
                }

                history(progress.filter { !$0.outcome.isOpen })
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(20)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .navigationTitle("Fokus")
        .confirmationDialog("Diesen Lauf aus dem Verlauf entfernen?",
                            isPresented: .constant(runToDelete != nil),
                            presenting: runToDelete) { run in
            Button("Entfernen", role: .destructive) {
                Task { await state.deleteFocusRun(run.id) }
                runToDelete = nil
            }
            Button("Abbrechen", role: .cancel) { runToDelete = nil }
        } message: { run in
            Text("„\(run.displayTitle)“ vom \(run.startsOn.shortLabel) verschwindet dauerhaft.")
        }
    }

    // MARK: - Starten

    private var startCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Fokus starten").font(.headline)
            Text("Ein Fokus läuft ab heute und ist geschafft, wenn an jedem Tag alles erledigt ist, was ansteht. Ein Ruhetag oder Urlaub bricht ihn nicht — ein Streak Freeze rettet ihn aber auch nicht.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Picker("Länge", selection: $days) {
                    Text("3 Tage").tag(3)
                    Text("7 Tage").tag(7)
                    Text("14 Tage").tag(14)
                    Text("30 Tage").tag(30)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 300)

                Text("bis \(state.today.adding(days: days - 1).shortLabel)")
                    .font(.callout).foregroundStyle(.secondary)
            }

            TextField("Name (optional)", text: $title)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)

            Picker("Umfang", selection: $scopeIsSelection) {
                Text("Alle Habits").tag(false)
                Text("Auswahl").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 240)

            if scopeIsSelection {
                Text("Ein Fokus über alle Habits reißt am ersten schwachen Tag. Über drei ausgewählte ist er zu schaffen.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(state.habits) { habit in
                        Toggle(isOn: binding(for: habit.id)) {
                            Label {
                                Text(habit.name)
                            } icon: {
                                Image(systemName: habit.symbol)
                                    .foregroundStyle(Color(hex: habit.colorHex))
                            }
                        }
                    }
                }
            }

            Button("Fokus starten") {
                Task {
                    await state.startFocus(
                        days: days,
                        habitIds: scopeIsSelection ? Array(selection) : [],
                        title: title.trimmingCharacters(in: .whitespaces).isEmpty ? nil : title)
                    title = ""
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(state.habits.isEmpty || (scopeIsSelection && selection.isEmpty))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private func binding(for id: UUID) -> Binding<Bool> {
        Binding(get: { selection.contains(id) },
                set: { isOn in
                    if isOn { selection.insert(id) } else { selection.remove(id) }
                })
    }

    // MARK: - Verlauf

    @ViewBuilder
    private func history(_ finished: [FocusProgress]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Verlauf").font(.headline)

            if finished.isEmpty {
                Text("Noch kein abgeschlossener Lauf.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(finished, id: \.run.id) { progress in
                    row(progress)
                    if progress.run.id != finished.last?.run.id { Divider() }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private func row(_ progress: FocusProgress) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(progress.run.displayTitle).font(.body.weight(.medium))
                    FocusOutcomeBadge(outcome: progress.outcome)
                }
                Text("\(progress.run.startsOn.shortLabel) – \(progress.run.endsOn.shortLabel)"
                     + " · \(scopeLabel(progress.run))")
                    .font(.caption).foregroundStyle(.secondary)
                FocusDayStrip(progress: progress, today: state.today, size: 18)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text("\(progress.perfectDays)/\(progress.plannedDays)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help("Geschaffte von den Tagen, an denen etwas anstand")
                Button {
                    runToDelete = progress.run
                } label: {
                    Image(systemName: "trash").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Aus dem Verlauf entfernen")
            }
        }
        .padding(.vertical, 4)
    }

    private func habitNames(_ run: FocusRun) -> [String] {
        run.habitIds.compactMap { id in state.habits.first { $0.id == id }?.name }
    }

    private func scopeLabel(_ run: FocusRun) -> String {
        let names = habitNames(run)
        if run.habitIds.isEmpty { return "alle Habits" }
        if names.isEmpty { return "\(run.habitIds.count) Habits" }
        return names.count <= 2
            ? names.joined(separator: ", ")
            : "\(names.prefix(2).joined(separator: ", ")) und \(names.count - 2) weitere"
    }
}
