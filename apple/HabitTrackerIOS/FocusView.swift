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
            VStack(alignment: .leading, spacing: 18) {
                let progress = state.focusProgress

                if !progress.isEmpty {
                    HStack(alignment: .top, spacing: 24) {
                        FocusRecordRow(record: state.focusRecord)
                        Spacer(minLength: 0)
                        freezeGuthaben
                    }
                }

                if let active = state.activeFocus {
                    FocusBanner(progress: active, today: state.today,
                                habitNames: habitNames(active.run)) {
                        Task { await state.abandonFocus(active.run.id) }
                    }
                    // Das Formular fehlt hier mit Absicht — aber wortlos
                    // auszublenden hieße, den Nutzer raten zu lassen, warum.
                    Label(blockedReason(active), systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    startKarte
                }

                verlauf(progress.filter { !$0.outcome.isOpen })
            }
            .padding(16)
        }
        .navigationTitle("Fokus")
        .navigationBarTitleDisplayMode(.inline)
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

    /// Warum gerade kein neuer Lauf beginnen kann.
    private func blockedReason(_ active: FocusProgress) -> String {
        if active.run.startsOn > state.today {
            return "„\(active.run.displayTitle)“ beginnt erst am \(active.run.startsOn.shortLabel) "
                + "Einen neuen kannst du starten, sobald er vorbei ist — oder wenn du ihn oben abbrichst."
        }
        return "Es läuft bereits ein Fokus bis zum \(active.run.endsOn.shortLabel) "
            + "Einen neuen kannst du starten, sobald er vorbei ist — oder wenn du ihn oben abbrichst. "
            + "Ein gerissener Lauf blockiert nicht."
    }

    /// Das Freeze-Guthaben — hier, weil es hier verdient wird.
    private var freezeGuthaben: some View {
        VStack(alignment: .trailing, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: "snowflake").font(.callout)
                Text("\(state.freezeBalance)").font(.title2).monospacedDigit()
            }
            .foregroundStyle(state.freezeBalance > 0 ? .cyan : .secondary)
            Text(state.freezeBalance == 1 ? "Freeze" : "Freezes")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Starten

    private var startKarte: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Fokus starten").font(.headline)
            Text("Ein Fokus läuft ab heute und ist geschafft, wenn an jedem Tag alles erledigt ist, was ansteht. Ein Ruhetag oder Urlaub bricht ihn nicht — ein Streak Freeze rettet ihn aber auch nicht.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Länge", selection: $days) {
                Text("3").tag(3)
                Text("7").tag(7)
                Text("14").tag(14)
                Text("30").tag(30)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text("bis \(state.today.adding(days: days - 1).shortLabel)")
                .font(.callout).foregroundStyle(.secondary)

            TextField("Name (optional)", text: $title)
                .textFieldStyle(.roundedBorder)

            Picker("Umfang", selection: $scopeIsSelection) {
                Text("Alle Habits").tag(false)
                Text("Auswahl").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if scopeIsSelection {
                Text("Ein Fokus über alle Habits reißt am ersten schwachen Tag. Über drei ausgewählte ist er zu schaffen.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 6) {
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
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)
            .disabled(state.habits.isEmpty || (scopeIsSelection && selection.isEmpty))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }

    private func binding(for id: UUID) -> Binding<Bool> {
        Binding(get: { selection.contains(id) },
                set: { isOn in
                    if isOn { selection.insert(id) } else { selection.remove(id) }
                })
    }

    // MARK: - Verlauf

    @ViewBuilder
    private func verlauf(_ laeufe: [FocusProgress]) -> some View {
        if !laeufe.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Verlauf").font(.headline)
                ForEach(laeufe, id: \.run.id) { lauf in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(lauf.run.displayTitle).font(.callout.weight(.medium))
                            Spacer()
                            FocusOutcomeBadge(outcome: lauf.outcome)
                        }
                        Text("\(lauf.run.startsOn.shortLabel) – \(lauf.run.endsOn.shortLabel) · "
                             + "\(lauf.perfectDays) von \(lauf.plannedDays) geschafft")
                            .font(.caption).foregroundStyle(.secondary)
                        FocusDayStrip(progress: lauf, today: state.today)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                    // Kein `.swipeActions`: das wirkt nur in einer `List`,
                    // und hier stehen Karten. Langes Drücken ist die Geste,
                    // die überall funktioniert.
                    .contextMenu {
                        Button("Aus dem Verlauf entfernen", role: .destructive) {
                            runToDelete = lauf.run
                        }
                    }
                }
            }
        }
    }

    private func habitNames(_ run: FocusRun) -> [String] {
        run.habitIds.compactMap { state.habit($0)?.name }
    }
}
