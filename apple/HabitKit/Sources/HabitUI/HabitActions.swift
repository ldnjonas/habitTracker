import SwiftUI
import HabitCore

/// Die Aktionen zu einem Habit — einmal geschrieben, an drei Stellen benutzt.
///
/// Als lose Knopfreihe und nicht als fertiges `Menu`, damit derselbe Satz
/// sowohl in ein `contextMenu` als auch in einen „…"-Knopf passt. Zwei Kopien
/// hätten sich beim nächsten neuen Eintrag auseinanderentwickelt.
public struct HabitActions: View {
    public var habit: Habit
    public var onEdit: () -> Void
    public var onArchive: () -> Void
    public var onUnarchive: () -> Void
    public var onDelete: () -> Void

    public init(
        habit: Habit,
        onEdit: @escaping () -> Void,
        onArchive: @escaping () -> Void,
        onUnarchive: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.habit = habit
        self.onEdit = onEdit
        self.onArchive = onArchive
        self.onUnarchive = onUnarchive
        self.onDelete = onDelete
    }

    public var body: some View {
        Button(action: onEdit) {
            Label("Bearbeiten …", systemImage: "pencil")
        }

        if habit.isArchived {
            Button(action: onUnarchive) {
                Label("Aus dem Archiv holen", systemImage: "tray.and.arrow.up")
            }
        } else {
            Button(action: onArchive) {
                Label("Archivieren", systemImage: "archivebox")
            }
        }

        Divider()

        Button(role: .destructive, action: onDelete) {
            // Die Auslassungspunkte sind auf dem Mac das Versprechen, dass
            // noch eine Rückfrage kommt — und hier kommt sie auch.
            Label("Löschen …", systemImage: "trash")
        }
    }
}

/// Der sichtbare „…"-Knopf.
///
/// Ohne ihn war Löschen nur per Rechtsklick erreichbar — eine Funktion, von der
/// man wissen muss, dass es sie gibt, um sie zu finden.
public struct HabitMenuButton: View {
    public var habit: Habit
    public var onEdit: () -> Void
    public var onArchive: () -> Void
    public var onUnarchive: () -> Void
    public var onDelete: () -> Void

    public init(
        habit: Habit,
        onEdit: @escaping () -> Void,
        onArchive: @escaping () -> Void,
        onUnarchive: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.habit = habit
        self.onEdit = onEdit
        self.onArchive = onArchive
        self.onUnarchive = onUnarchive
        self.onDelete = onDelete
    }

    public var body: some View {
        Menu {
            HabitActions(habit: habit, onEdit: onEdit, onArchive: onArchive,
                         onUnarchive: onUnarchive, onDelete: onDelete)
        } label: {
            Image(systemName: "ellipsis.circle")
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Bearbeiten, archivieren, löschen")
    }
}
