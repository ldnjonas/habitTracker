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
        // `.borderlessButton` gibt es nur auf dem Mac. Auf iOS ist der
        // Vorgabestil ohnehin der richtige — dort ist ein Menü ein Blatt, kein
        // Aufklappfeld.
        #if os(macOS)
        .menuStyle(.borderlessButton)
        #endif
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Bearbeiten, archivieren, löschen")
    }
}


/// „Nach oben" und „Nach unten" für ein Kontextmenü.
///
/// Verschieben ohne Ziehen. Eine Reihenfolge, die nur per Drag erreichbar ist,
/// ist für Tastaturnutzer keine — und wenn das Ziehen einmal klemmt, für alle
/// keine. Getrennt von `HabitActions`, weil es die Position in der Liste
/// braucht und die nicht überall bekannt ist.
public struct HabitMoveActions: View {
    public var index: Int
    public var count: Int
    /// Bekommt Quelle und Ziel wie `onMove`.
    public var onMove: (IndexSet, Int) -> Void

    public init(index: Int, count: Int, onMove: @escaping (IndexSet, Int) -> Void) {
        self.index = index
        self.count = count
        self.onMove = onMove
    }

    public var body: some View {
        Divider()

        Button {
            onMove(IndexSet(integer: index), index - 1)
        } label: {
            Label("Nach oben", systemImage: "arrow.up")
        }
        .disabled(index == 0)

        Button {
            // `move` bestimmt das Ziel vor dem Entfernen — eine Position tiefer
            // ist deshalb index + 2, nicht index + 1.
            onMove(IndexSet(integer: index), index + 2)
        } label: {
            Label("Nach unten", systemImage: "arrow.down")
        }
        .disabled(index == count - 1)
    }
}
