import SwiftUI
import HabitCore

/// Ausnahmen anlegen: Urlaub oder Ruhetag.
///
/// **Eingefroren fehlt hier mit Absicht.** Ein Freeze ist etwas, das man sich
/// verdient und einlöst; wäre er frei erzeugbar, wäre das Guthaben wertlos und
/// jeder Streak beliebig zu retten. Er entsteht deshalb nur über das Guthaben,
/// nicht über dieses Blatt.
///
/// Wie `HabitEditorForm` ohne Kenntnis von `AppState` gebaut — die Ansicht
/// meldet, was gewünscht ist, das Schreiben macht der Aufrufer.
public struct ExceptionEditor: View {
    /// Die Arten, die man selbst setzen darf.
    public static let selectableKinds: [ExceptionKind] = [.paused, .skipped]

    public var habits: [Habit]
    public var today: CalendarDate
    public var initialDate: CalendarDate
    public var onSave: (ExceptionKind, CalendarDate, CalendarDate, [UUID], String?) -> Void
    public var onCancel: () -> Void

    @State private var kind: ExceptionKind = .paused
    @State private var from: Date
    @State private var to: Date
    @State private var spansRange = false
    @State private var reason = ""
    @State private var scopeIsSelection = false
    @State private var selection: Set<UUID> = []

    public init(
        habits: [Habit],
        today: CalendarDate,
        initialDate: CalendarDate,
        onSave: @escaping (ExceptionKind, CalendarDate, CalendarDate, [UUID], String?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.habits = habits
        self.today = today
        self.initialDate = initialDate
        self.onSave = onSave
        self.onCancel = onCancel
        let start = initialDate.asDate()
        _from = State(initialValue: start)
        _to = State(initialValue: start)
    }

    private var fromDay: CalendarDate { CalendarDate(from) }
    private var toDay: CalendarDate { spansRange ? CalendarDate(to) : fromDay }
    private var dayCount: Int { max(0, fromDay.days(until: toDay)) + 1 }
    private var isValid: Bool {
        toDay >= fromDay && !(scopeIsSelection && selection.isEmpty)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Ausnahme eintragen").font(.title2).bold().padding(20)

            Divider()

            Form {
                Section {
                    Picker("Art", selection: $kind) {
                        ForEach(ExceptionEditor.selectableKinds, id: \.self) {
                            Text($0.label).tag($0)
                        }
                    }
                    // Auf dem Mac untereinander, auf dem Telefon nebeneinander:
                    // drei Radioknöpfe in einer Liste sehen dort falsch aus, und
                    // `.radioGroup` gibt es auf iOS gar nicht.
                    #if os(macOS)
                    .pickerStyle(.radioGroup)
                    #else
                    .pickerStyle(.segmented)
                    #endif

                    Text(explanation)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section("Zeitraum") {
                    Toggle("Mehrere Tage", isOn: $spansRange)
                    DatePicker(spansRange ? "Von" : "Tag", selection: $from,
                               displayedComponents: .date)
                    if spansRange {
                        DatePicker("Bis", selection: $to, in: from..., displayedComponents: .date)
                        LabeledContent("Umfang",
                                       value: dayCount == 1 ? "1 Tag" : "\(dayCount) Tage")
                    }
                }

                Section("Gilt für") {
                    Picker("Umfang", selection: $scopeIsSelection) {
                        Text("Alle Habits").tag(false)
                        Text("Auswahl").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    if scopeIsSelection {
                        ForEach(habits) { habit in
                            Toggle(isOn: binding(for: habit.id)) {
                                Label {
                                    Text(habit.name)
                                } icon: {
                                    Image(systemName: habit.symbol)
                                        .foregroundStyle(Color(hex: habit.colorHex))
                                }
                            }
                        }
                    } else {
                        Text("Auch für Habits, die du später anlegst — die Ausnahme hängt am Tag, nicht am Habit.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Section("Grund") {
                    TextField("optional, z. B. „Urlaub in Italien“", text: $reason)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button("Abbrechen", action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Eintragen") {
                    onSave(kind, fromDay, toDay,
                           scopeIsSelection ? Array(selection) : [],
                           reason.trimmingCharacters(in: .whitespaces).isEmpty ? nil : reason)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
            .padding(20)
        }
        // Ein Blatt auf dem Mac braucht eine Größe, auf dem Telefon füllt es
        // den Bildschirm — eine feste Breite wäre dort ein zu kleines Fenster
        // in einem großen.
        #if os(macOS)
        .frame(width: 460, height: 560)
        #endif
    }

    private var explanation: String {
        switch kind {
        case .paused:
            "Der Tag war nie vorgesehen: er fällt aus Streak und Quote ganz heraus, als hätte es ihn nicht gegeben."
        case .skipped:
            "Ein bewusster Ruhetag — wie Urlaub, nur für einen einzelnen Tag gedacht."
        case .frozen:
            "Rettet den Streak, zählt in der Quote aber weiter als verpasst."
        }
    }

    private func binding(for id: UUID) -> Binding<Bool> {
        Binding(get: { selection.contains(id) },
                set: { isOn in
                    if isOn { selection.insert(id) } else { selection.remove(id) }
                })
    }
}
