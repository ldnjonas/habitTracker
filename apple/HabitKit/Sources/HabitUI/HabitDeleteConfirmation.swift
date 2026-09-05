import SwiftUI
import HabitCore

/// Die Rückfrage vor dem Löschen — mit dem Symbol des Habits.
///
/// Bewusst ein eigenes Blatt statt `confirmationDialog`: dessen Icon liefert
/// das System (das App-Icon) und lässt sich nicht ersetzen. Beim Löschen soll
/// aber zu sehen sein, *was* gelöscht wird — der Name allein ist bei
/// „PhysioÜbungen" und „SpracheLernen" schnell verwechselt.
public struct HabitDeleteConfirmation: View {
    public var habit: Habit
    public var trashWindowDays: Int
    public var onCancel: () -> Void
    public var onDelete: () -> Void

    public init(
        habit: Habit,
        trashWindowDays: Int,
        onCancel: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.habit = habit
        self.trashWindowDays = trashWindowDays
        self.onCancel = onCancel
        self.onDelete = onDelete
    }

    private var color: Color { Color(hex: habit.colorHex) }

    public var body: some View {
        VStack(spacing: 14) {
            Image(systemName: habit.symbol)
                .font(.system(size: 26))
                .foregroundStyle(color)
                .frame(width: 58, height: 58)
                .background(color.opacity(0.15), in: Circle())

            VStack(spacing: 6) {
                Text("„\(habit.name)“ löschen?")
                    .font(.headline)
                    .multilineTextAlignment(.center)

                Text("Der Habit und sein gesamter Verlauf liegen \(trashWindowDays) Tage im Papierkorb und lassen sich von dort zurückholen.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                // Esc bricht ab; „Löschen" bekommt bewusst keine Eingabetaste —
                // ein Versehen soll nicht am Reflex hängen.
                Button(action: onCancel) {
                    Text("Abbrechen").frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.cancelAction)

                Button(role: .destructive, action: onDelete) {
                    // `role: .destructive` färbt nur in System-Dialogen. Hier,
                    // im eigenen Blatt, muss die Warnfarbe von Hand kommen —
                    // sonst sieht der unwiderrufliche Knopf aus wie der andere.
                    Text("Löschen")
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity)
                }
            }
            .controlSize(.large)
            .padding(.top, 2)
        }
        .padding(22)
        .frame(width: 300)
    }
}
