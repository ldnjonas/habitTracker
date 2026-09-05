import SwiftUI
import HabitCore

public extension JournalMetric {
    var label: String {
        switch self {
        case .mood: "Stimmung"
        case .energy: "Energie"
        case .sleepHours: "Schlaf"
        }
    }

    var symbolName: String {
        switch self {
        case .mood: "face.smiling"
        case .energy: "bolt.fill"
        case .sleepHours: "bed.double.fill"
        }
    }
}

/// Das Tages-Journal: Stimmung, Energie, Schlaf, Notiz.
///
/// Alles freiwillig — ein Journal, das vollständig sein muss, wird gar nicht
/// geführt. Nicht Erfasstes fällt aus der Auswertung heraus, statt als Null zu
/// zählen.
public struct DayLogEditor: View {
    public var date: CalendarDate
    public var existing: DayLog?
    public var onSave: (DayLog) -> Void
    public var onCancel: () -> Void

    @State private var mood: Int?
    @State private var energy: Int?
    @State private var sleepHours: Double?
    @State private var note: String

    public init(
        date: CalendarDate,
        existing: DayLog?,
        onSave: @escaping (DayLog) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.date = date
        self.existing = existing
        self.onSave = onSave
        self.onCancel = onCancel
        _mood = State(initialValue: existing?.mood)
        _energy = State(initialValue: existing?.energy)
        _sleepHours = State(initialValue: existing?.sleepHours)
        _note = State(initialValue: existing?.note ?? "")
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Journal").font(.title2).bold()
                Text(date.longLabel).font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(20)

            Divider()

            Form {
                Section {
                    scale("Stimmung", systemImage: "face.smiling", value: $mood)
                    scale("Energie", systemImage: "bolt.fill", value: $energy)
                } footer: {
                    Text("1 ist schlecht, 5 ist gut. Was du weglässt, fällt aus der Auswertung heraus — es zählt nicht als Null.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    HStack {
                        Label("Schlaf", systemImage: "bed.double.fill")
                        Spacer()
                        if let stunden = sleepHours {
                            Text(formatMinutes(stunden * 60)).monospacedDigit()
                            Button {
                                sleepHours = nil
                            } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                            .help("Angabe entfernen")
                        } else {
                            Button("Eintragen") { sleepHours = 7.5 }
                                .controlSize(.small)
                        }
                    }
                    if sleepHours != nil {
                        Slider(value: Binding(get: { sleepHours ?? 7.5 },
                                              set: { sleepHours = ($0 * 4).rounded() / 4 }),
                               in: 0...14, step: 0.25)
                    }
                }

                Section("Notiz") {
                    TextField("optional", text: $note, axis: .vertical)
                        .lineLimit(3...6)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button("Abbrechen", action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Sichern") {
                    var log = existing ?? DayLog(date: date)
                    log.mood = mood
                    log.energy = energy
                    log.sleepHours = sleepHours
                    log.note = note.trimmingCharacters(in: .whitespaces).isEmpty ? nil : note
                    log.updatedAt = Date()
                    onSave(log)
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 440, height: 520)
    }

    /// Eine 1–5-Skala, die sich auch wieder leeren lässt.
    private func scale(_ title: String, systemImage: String, value: Binding<Int?>) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            ForEach(1...5, id: \.self) { stufe in
                Button {
                    // Nochmal auf dieselbe Stufe nimmt die Angabe zurück.
                    value.wrappedValue = value.wrappedValue == stufe ? nil : stufe
                } label: {
                    Circle()
                        .fill(stufe <= (value.wrappedValue ?? 0)
                              ? Color.accentColor : Color.secondary.opacity(0.18))
                        .frame(width: 22, height: 22)
                        .overlay {
                            Text("\(stufe)")
                                .font(.caption2)
                                .foregroundStyle(stufe <= (value.wrappedValue ?? 0)
                                                 ? .white : .secondary)
                        }
                }
                .buttonStyle(.plain)
                .help(stufe == value.wrappedValue ? "Angabe zurücknehmen" : "\(stufe) von 5")
            }
        }
    }
}
