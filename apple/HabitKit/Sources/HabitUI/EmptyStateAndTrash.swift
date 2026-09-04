import SwiftUI
import HabitCore
import HabitStore

/// Erster Start: Vorlagen statt eines leeren Bildschirms.
///
/// Ein leerer Zustand mit nur einem „+" verlangt vom Nutzer, sich sein System
/// selbst auszudenken. Zwölf Vorschläge nehmen ihm diese Entscheidung ab.
public struct TemplatePicker: View {
    public var today: CalendarDate
    public var onPick: (HabitDraft) -> Void
    public var onCreateOwn: () -> Void

    @State private var picked: Set<String> = []

    public init(today: CalendarDate,
                onPick: @escaping (HabitDraft) -> Void,
                onCreateOwn: @escaping () -> Void) {
        self.today = today
        self.onPick = onPick
        self.onCreateOwn = onCreateOwn
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 6) {
                    Image(systemName: "checklist")
                        .font(.system(size: 40))
                        .foregroundStyle(.tint)
                    Text("Womit fängst du an?")
                        .font(.title2.weight(.semibold))
                    Text("Such dir etwas aus oder leg deinen eigenen Habit an. Ändern lässt sich später alles.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                }
                .padding(.top, 40)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 12)], spacing: 12) {
                    ForEach(HabitTemplate.all) { template in
                        card(template)
                    }
                }
                .padding(.horizontal)

                Button("Eigenen Habit anlegen …", action: onCreateOwn)
                    .padding(.bottom, 30)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func card(_ template: HabitTemplate) -> some View {
        let color = Color(hex: template.colorHex)
        let isPicked = picked.contains(template.id)
        return Button {
            guard !isPicked else { return }
            picked.insert(template.id)
            onPick(template.draft(startingOn: today))
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isPicked ? "checkmark" : template.symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isPicked ? .white : color)
                    .frame(width: 34, height: 34)
                    .background(isPicked ? color : color.opacity(0.15), in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(template.name)
                        .font(.body.weight(.medium))
                    Text(template.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isPicked ? color : .clear, lineWidth: 1.5)
            }
        }
        .buttonStyle(.plain)
    }
}

/// Papierkorb der letzten 30 Tage.
public struct TrashView: View {
    public var items: [TrashItem]
    public var onRestore: (TrashItem) -> Void

    public init(items: [TrashItem], onRestore: @escaping (TrashItem) -> Void) {
        self.items = items
        self.onRestore = onRestore
    }

    public var body: some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView("Papierkorb ist leer",
                                       systemImage: "trash",
                                       description: Text("Gelöschtes lässt sich hier 30 Tage lang zurückholen."))
            } else {
                List(items) { item in
                    HStack {
                        Image(systemName: symbol(item.table))
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.label)
                            Text(label(item.table))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Wiederherstellen") { onRestore(item) }
                            .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .navigationTitle("Papierkorb")
    }

    private func symbol(_ table: TrashItem.Table) -> String {
        switch table {
        case .habit: "circle.dashed"
        case .entry, .entryEvent: "checkmark.circle"
        case .dayException: "snowflake"
        case .dayLog: "text.book.closed"
        case .tag: "tag"
        }
    }

    private func label(_ table: TrashItem.Table) -> String {
        switch table {
        case .habit: "Habit"
        case .entry: "Eintrag"
        case .entryEvent: "Zeitstempel"
        case .dayException: "Ausnahme"
        case .dayLog: "Journal"
        case .tag: "Tag"
        }
    }
}
