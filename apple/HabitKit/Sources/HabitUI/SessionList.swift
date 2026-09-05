import SwiftUI
import HabitCore

/// Die Sitzungen eines Tages: Start, Ende, Dauer.
///
/// Sichtbar nur für Habits mit `tracksTime`. Der Tageswert ergibt sich aus der
/// Summe — deshalb gibt es hier kein Feld dafür: eine Zahl, die man neben den
/// Sitzungen von Hand setzen kann, widerspräche ihnen früher oder später.
public struct SessionList: View {
    public var habit: Habit
    public var date: CalendarDate
    public var sessions: [EntryEvent]
    public var onAdd: (Date, Date) -> Void
    public var onDelete: (EntryEvent) -> Void

    @State private var start: Date
    @State private var end: Date
    @State private var showsForm = false

    public init(
        habit: Habit,
        date: CalendarDate,
        sessions: [EntryEvent],
        onAdd: @escaping (Date, Date) -> Void,
        onDelete: @escaping (EntryEvent) -> Void
    ) {
        self.habit = habit
        self.date = date
        self.sessions = sessions
        self.onAdd = onAdd
        self.onDelete = onDelete
        // Vorschlag: die letzte volle Stunde bis jetzt — meist trägt man nach,
        // was man gerade getan hat.
        let jetzt = date.asDate()
        _start = State(initialValue: jetzt.addingTimeInterval(-3600))
        _end = State(initialValue: jetzt)
    }

    private var total: Double { sessions.reduce(0) { $0 + $1.effectiveValue } }
    private var isValid: Bool { end > start }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(date.longLabel).font(.subheadline.weight(.medium))
                Spacer()
                if !sessions.isEmpty {
                    Text(formatMinutes(total))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(Color(hex: habit.colorHex))
                }
            }

            if sessions.isEmpty && !showsForm {
                Text("Noch keine Sitzung an diesem Tag.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            ForEach(sessions) { session in
                HStack(spacing: 10) {
                    Image(systemName: "clock")
                        .foregroundStyle(.secondary).frame(width: 16)
                    Text(session.endsAt.map { "\(formatClock(session.at)) – \(formatClock($0))" }
                         ?? formatClock(session.at))
                        .monospacedDigit()
                    if let note = session.note {
                        Text(note).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(formatMinutes(session.effectiveValue))
                        .foregroundStyle(.secondary).monospacedDigit()
                    Button {
                        onDelete(session)
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Sitzung entfernen")
                }
                .font(.callout)
            }

            if showsForm {
                HStack(spacing: 10) {
                    DatePicker("Von", selection: $start, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                    Text("bis").foregroundStyle(.secondary)
                    DatePicker("Bis", selection: $end, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                    if isValid {
                        Text(formatMinutes(end.timeIntervalSince(start) / 60))
                            .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    } else {
                        Text("Ende muss nach dem Start liegen")
                            .font(.caption).foregroundStyle(.red)
                    }
                    Spacer()
                    Button("Sichern") {
                        onAdd(start, end)
                        showsForm = false
                    }
                    .disabled(!isValid)
                    Button("Abbrechen") { showsForm = false }
                }
            } else {
                Button {
                    showsForm = true
                } label: {
                    Label("Sitzung hinzufügen", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        }
    }
}

// MARK: - Wochensumme

/// Was in einem Zeitraum zusammenkam, mit einem Balken je Woche.
public struct PeriodTotalPanel: View {
    public var habit: Habit
    public var total: PeriodTotal
    public var today: CalendarDate

    public init(habit: Habit, total: PeriodTotal, today: CalendarDate) {
        self.habit = habit
        self.total = total
        self.today = today
    }

    private var color: Color { Color(hex: habit.colorHex) }
    private var isTime: Bool { habit.tracksTime }
    private var maxWeek: Double { max(total.byWeek.values.max() ?? 0, 1) }

    private func format(_ value: Double) -> String {
        isTime ? formatMinutes(value)
               : "\(value.formatted(.number.precision(.fractionLength(0...1)))) \(habit.target(on: today)?.unit ?? "")"
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 28) {
                metric(format(thisWeek), "diese Woche")
                metric(format(total.total), "im Zeitraum")
                if let schnitt = total.averagePerActiveDay {
                    metric(format(schnitt), "je aktivem Tag")
                }
                metric("\(total.activeDays)", total.activeDays == 1 ? "aktiver Tag" : "aktive Tage")
                Spacer()
            }

            if total.byWeek.count > 1 {
                weeks
            }
        }
    }

    private var thisWeek: Double { total.byWeek[today.weekStart] ?? 0 }

    /// Die letzten Wochen als Balken — nur bis heute, damit die laufende Woche
    /// nicht neben lauter leeren Zukunftswochen steht.
    private var weeks: some View {
        let sortiert = total.byWeek.keys.filter { $0 <= today.weekStart }.sorted().suffix(12)
        return HStack(alignment: .bottom, spacing: 6) {
            ForEach(Array(sortiert), id: \.self) { week in
                let value = total.byWeek[week] ?? 0
                VStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(week == today.weekStart ? color : color.opacity(0.45))
                        .frame(height: max(3, 56 * value / maxWeek))
                    Text(week.shortLabel)
                        .font(.system(size: 8)).foregroundStyle(.secondary)
                        .fixedSize()
                }
                .frame(maxWidth: .infinity)
                .help("\(week.shortLabel) – \(week.weekEnd.shortLabel): \(format(value))")
            }
        }
        .frame(height: 76, alignment: .bottom)
    }

    private func metric(_ value: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3).monospacedDigit()
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
    }
}
