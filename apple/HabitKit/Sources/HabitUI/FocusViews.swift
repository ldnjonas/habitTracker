import SwiftUI
import HabitCore

// MARK: - Beschriftungen

public extension FocusOutcome {
    var label: String {
        switch self {
        case .upcoming: "beginnt noch"
        case .running(let day, let total): "Tag \(day) von \(total)"
        case .completed: "durchgezogen"
        case .failed(let date): "gerissen am \(date.shortLabel)"
        case .abandoned(let date): "abgebrochen am \(date.shortLabel)"
        }
    }

    var symbolName: String {
        switch self {
        case .upcoming: "clock"
        case .running: "flame.fill"
        case .completed: "checkmark.seal.fill"
        case .failed: "xmark.seal"
        case .abandoned: "minus.circle"
        }
    }

    var tint: Color {
        switch self {
        case .upcoming: .secondary
        case .running: .orange
        case .completed: .green
        case .failed: .red
        case .abandoned: .secondary
        }
    }
}

/// Kurze Plakette für Listen.
public struct FocusOutcomeBadge: View {
    public var outcome: FocusOutcome

    public init(outcome: FocusOutcome) { self.outcome = outcome }

    public var body: some View {
        Label(outcome.label, systemImage: outcome.symbolName)
            .font(.caption.weight(.medium))
            .foregroundStyle(outcome.tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(outcome.tint.opacity(0.12), in: Capsule())
    }
}

// MARK: - Tagesstreifen

/// Die Tage eines Laufs als Kette — geschafft, gerissen, offen.
///
/// Das Bild soll auf einen Blick beantworten, wo man steht: bei sieben Tagen
/// zählt man keine Prozente, man sieht die Lücke.
public struct FocusDayStrip: View {
    public var progress: FocusProgress
    public var today: CalendarDate
    public var size: CGFloat

    public init(progress: FocusProgress, today: CalendarDate, size: CGFloat = 26) {
        self.progress = progress
        self.today = today
        self.size = size
    }

    public var body: some View {
        HStack(spacing: 4) {
            ForEach(progress.run.startsOn.through(progress.run.endsOn), id: \.self) { date in
                day(date)
            }
        }
    }

    private func day(_ date: CalendarDate) -> some View {
        let summary = progress.days[date]
        let isFuture = date > today
        let isPerfect = summary?.isPerfect ?? false
        // Ein Tag ohne Plan ist keine Lücke — es gab nichts zu verpassen.
        let nothingPlanned = (summary?.scheduled ?? 0) == 0
        // Nur vergangene Tage können reißen. Heute ist noch offen — sonst
        // widerspräche der Streifen der Auswertung, die den laufenden Tag
        // ausdrücklich nicht als Lücke wertet.
        let isGap = date < today && !isPerfect && !nothingPlanned

        return RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(fill(isPerfect: isPerfect, nothingPlanned: nothingPlanned,
                       isGap: isGap, isFuture: isFuture, isToday: date == today))
            .frame(width: size, height: size)
            .overlay {
                if date == today {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.55), lineWidth: 1.5)
                }
                if isPerfect {
                    Image(systemName: "checkmark")
                        .font(.system(size: size * 0.4, weight: .bold))
                        .foregroundStyle(.white)
                } else if isGap {
                    Image(systemName: "xmark")
                        .font(.system(size: size * 0.36, weight: .bold))
                        .foregroundStyle(.red.opacity(0.85))
                }
            }
            .help("\(date.longLabel) — \(dayLabel(date, isPerfect: isPerfect, nothingPlanned: nothingPlanned, isGap: isGap, isFuture: isFuture))")
    }

    private func fill(isPerfect: Bool, nothingPlanned: Bool,
                      isGap: Bool, isFuture: Bool, isToday: Bool) -> Color {
        if isPerfect { return .green.opacity(0.85) }
        if isGap { return .red.opacity(0.16) }
        // Heute ist weder geschafft noch verloren: der Tag, an dem es liegt.
        if isToday { return .orange.opacity(0.18) }
        if nothingPlanned && !isFuture { return .secondary.opacity(0.10) }
        return .secondary.opacity(0.14)
    }

    private func dayLabel(_ date: CalendarDate, isPerfect: Bool, nothingPlanned: Bool,
                          isGap: Bool, isFuture: Bool) -> String {
        if isPerfect { return "geschafft" }
        if isGap { return "Lücke" }
        if isFuture { return "steht noch aus" }
        if nothingPlanned { return "nichts geplant" }
        return date == today ? "heute noch offen" : "offen"
    }
}

// MARK: - Statuskarte

/// Der laufende Fokus im Kopf der Übersicht.
public struct FocusBanner: View {
    public var progress: FocusProgress
    public var today: CalendarDate
    public var habitNames: [String]
    public var onAbandon: (() -> Void)?

    public init(progress: FocusProgress, today: CalendarDate,
                habitNames: [String] = [], onAbandon: (() -> Void)? = nil) {
        self.progress = progress
        self.today = today
        self.habitNames = habitNames
        self.onAbandon = onAbandon
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: progress.outcome.symbolName)
                .font(.title)
                .foregroundStyle(progress.outcome.tint)
                .frame(width: 34)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(progress.run.displayTitle).font(.headline)
                    FocusOutcomeBadge(outcome: progress.outcome)
                }

                FocusDayStrip(progress: progress, today: today)

                Text(scopeText)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            if let onAbandon, progress.outcome.isOpen {
                Button("Abbrechen", action: onAbandon)
                    .help("Beendet den Fokus. Er erscheint im Verlauf als abgebrochen.")
            }
        }
        .padding(16)
        .background(progress.outcome.tint.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(progress.outcome.tint.opacity(0.30), lineWidth: 1)
        }
    }

    private var scopeText: String {
        let zeitraum = "\(progress.run.startsOn.shortLabel) – \(progress.run.endsOn.shortLabel)"
        guard !habitNames.isEmpty else { return "\(zeitraum) · alle Habits" }
        if habitNames.count <= 3 {
            return "\(zeitraum) · \(habitNames.joined(separator: ", "))"
        }
        return "\(zeitraum) · \(habitNames.prefix(2).joined(separator: ", ")) und \(habitNames.count - 2) weitere"
    }
}

// MARK: - Bilanz

public struct FocusRecordRow: View {
    public var record: FocusRecord

    public init(record: FocusRecord) { self.record = record }

    public var body: some View {
        HStack(alignment: .top, spacing: 28) {
            metric("\(record.completed)",
                   record.completed == 1 ? "durchgezogen" : "durchgezogen",
                   tint: .green)
            metric("\(record.failed)", record.failed == 1 ? "gerissen" : "gerissen", tint: .red)
            if record.abandoned > 0 {
                metric("\(record.abandoned)", "abgebrochen", tint: .secondary)
            }
            metric(record.successRate.map { "\(Int(($0 * 100).rounded()))\u{202F}%" } ?? "–",
                   "Quote", tint: .primary)
            metric("\(record.longestWinStreak)", "beste Serie", tint: .primary)
            Spacer()
        }
    }

    private func metric(_ value: String, _ caption: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title2).monospacedDigit().foregroundStyle(tint)
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
    }
}
