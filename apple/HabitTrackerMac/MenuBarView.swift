import SwiftUI
import HabitCore
import HabitUI

/// Die heutige Liste in der Menüleiste.
///
/// Der größte Alltagsgewinn der App: am Mac sitzt man ohnehin, und die Hürde
/// „Fenster suchen und öffnen" ist genau die, an der tägliches Abhaken scheitert.
///
/// Bewusst nur *heute* und nur Abhaken. Alles Weitere — Verlauf, Bearbeiten,
/// Ausnahmen — gehört ins Fenster; ein Menü, das alles kann, ist keins mehr.
struct MenuBarView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if state.todaysHabits.isEmpty {
                Text(state.habits.isEmpty
                     ? "Noch keine Habits angelegt."
                     : "Heute steht nichts an.")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.vertical, 16)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(state.todaysHabits) { habit in
                            row(habit)
                        }
                    }
                    .padding(.vertical, 6)
                }
                // Bei vielen Habits nicht ins Uferlose wachsen.
                .frame(maxHeight: 380)
            }

            if let focus = state.activeFocus {
                Divider()
                focusRow(focus)
            }

            Divider()
            footer
        }
        .frame(width: 300)
        // Das Fenster kann seit Stunden zu sein — beim Öffnen erst den Tag
        // nachziehen, dann neu lesen.
        // Auch von hier aus, damit eine App, die wochenlang offen steht, ihren
        // Abgleich und ihre tägliche Sicherung bekommt: das Hauptfenster lädt
        // sein `task` nur einmal, und geschlossen sein kann es auch.
        .task { await HabitTrackerApp.holeNach(state) }
    }

    // MARK: - Kopf

    private var header: some View {
        let progress = state.todaysProgress
        let share = progress.total == 0 ? 0 : Double(progress.done) / Double(progress.total)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(state.today.longLabel).font(.headline)
                Spacer()
                Text("\(progress.done) von \(progress.total)")
                    .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
            }
            ProgressView(value: share).progressViewStyle(.linear)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    // MARK: - Zeilen

    private func row(_ habit: Habit) -> some View {
        let status = state.status(habit, on: state.today)
        let value = state.value(habit, on: state.today)

        return Button {
            Task { await state.toggle(habit, on: state.today) }
        } label: {
            HStack(spacing: 10) {
                ProgressRing(progress: habit.progress(value: value, on: state.today),
                             color: Color(hex: habit.colorHex),
                             symbol: habit.symbol, size: 22)

                VStack(alignment: .leading, spacing: 1) {
                    Text(habit.name)
                        .strikethrough(status.isCompleted && habit.kind != .avoid,
                                       color: .secondary)
                    if habit.kind == .quantity, let target = habit.target(on: state.today) {
                        Text(habit.tracksTime
                             ? "\(formatMinutes(value)) von \(formatMinutes(target.value))"
                             : "\(value.formatted(.number.precision(.fractionLength(0...1)))) von \(target.value.formatted()) \(target.unit)")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }

                Spacer()

                if status.isCompleted {
                    Image(systemName: "checkmark")
                        .font(.caption.bold())
                        .foregroundStyle(Color(hex: habit.colorHex))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(habit.kind == .avoid
              ? (status.isCompleted ? "Verstoß melden" : "Verstoß zurücknehmen")
              : (status.isCompleted ? "Zurücknehmen" : "Erledigt"))
    }

    private func focusRow(_ focus: FocusProgress) -> some View {
        HStack(spacing: 8) {
            Image(systemName: focus.outcome.symbolName)
                .foregroundStyle(focus.outcome.tint)
            Text(focus.run.displayTitle).font(.callout)
            Spacer()
            Text(focus.outcome.label)
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    // MARK: - Fuß

    private var footer: some View {
        HStack {
            Button("Fenster öffnen") {
                openWindow(id: HabitTrackerApp.mainWindowID)
                NSApp.activate(ignoringOtherApps: true)
            }
            Spacer()
            Button("Beenden") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 14).padding(.vertical, 8)
    }
}
