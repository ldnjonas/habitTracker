import SwiftUI
import HabitCore

/// Woche oder Monat als Kalenderraster über alle Habits.
///
/// Die Jahresansicht (`OverviewHeatmapView`) muss 371 Tage auf eine Bildschirm-
/// breite bringen und kann deshalb nur Farbe zeigen. Hier ist Platz — also
/// stehen die Zahlen im Feld, statt nur im Tooltip zu stecken.
public struct OverviewCalendarGrid: View {
    public var summaries: [CalendarDate: DaySummary]
    public var span: OverviewSpan
    public var range: (from: CalendarDate, to: CalendarDate)
    public var today: CalendarDate
    public var scale: IntensityScale
    public var busiestDay: Int
    public var tint: Color
    public var selected: CalendarDate?
    public var onSelect: ((CalendarDate) -> Void)?

    public init(
        summaries: [CalendarDate: DaySummary],
        span: OverviewSpan,
        range: (from: CalendarDate, to: CalendarDate),
        today: CalendarDate,
        scale: IntensityScale = .count,
        busiestDay: Int,
        tint: Color = .accentColor,
        selected: CalendarDate? = nil,
        onSelect: ((CalendarDate) -> Void)? = nil
    ) {
        self.summaries = summaries
        self.span = span
        self.range = range
        self.today = today
        self.scale = scale
        self.busiestDay = busiestDay
        self.tint = tint
        self.selected = selected
        self.onSelect = onSelect
    }

    private var height: CGFloat { span == .week ? 96 : 54 }

    /// Wie viele Leerfelder vor dem ersten Tag stehen, damit er im richtigen
    /// Wochentag landet. Die Woche rastet schon auf Montag ein und braucht keine.
    private var leadingBlanks: Int {
        span == .week ? 0 : range.from.weekday.rawValue - 1
    }

    public var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(Weekday.allCases, id: \.self) { weekday in
                    Text(weekday.shortLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7),
                      spacing: 6) {
                ForEach(0..<leadingBlanks, id: \.self) { _ in
                    Color.clear.frame(height: height)
                }
                ForEach(range.from.through(range.to), id: \.self) { cell($0) }
            }
        }
        // Ohne Grenze zieht das Raster die Tageszellen auf Fensterbreite
        // auseinander; sie sehen dann nach Balken aus statt nach Kalender.
        .frame(maxWidth: 820, alignment: .leading)
    }

    @ViewBuilder
    private func cell(_ date: CalendarDate) -> some View {
        let summary = summaries[date]
        let isFuture = date > today
        let level = (isFuture || summary == nil)
            ? 0
            : intensityLevel(summary!, scale: scale, busiestDay: busiestDay)

        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(level > 0
                      ? tint.opacity(OverviewHeatmapView.opacity(for: level))
                      : Color.secondary.opacity(isFuture ? 0.05 : 0.11))

            if date == selected {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.primary, lineWidth: 2)
            } else if date == today {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.5), lineWidth: 1.5)
            }

            Text("\(date.day)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(level >= 3 ? .white : .secondary)
                .padding(5)

            if !isFuture, let summary, summary.scheduled > 0 {
                VStack(spacing: 0) {
                    Text("\(summary.completed)")
                        .font(span == .week ? .title2.bold() : .callout.weight(.medium))
                        .monospacedDigit()
                    Text("von \(summary.scheduled)")
                        .font(.system(size: span == .week ? 10 : 8))
                        .opacity(0.75)
                }
                .foregroundStyle(level >= 3 ? .white : .primary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: height)
        .contentShape(Rectangle())
        .help(tooltip(date, summary, isFuture: isFuture))
        .onTapGesture { onSelect?(date) }
    }

    private func tooltip(_ date: CalendarDate, _ summary: DaySummary?, isFuture: Bool) -> String {
        guard !isFuture else { return date.longLabel }
        guard let summary, summary.scheduled > 0 else {
            return "\(date.longLabel) — nichts geplant"
        }
        let base = "\(date.longLabel) — \(summary.completed) von \(summary.scheduled) erledigt"
        return summary.isPerfect ? base + " ✓" : base
    }
}

// MARK: - Beschriftungen

public extension OverviewSpan {
    var label: String {
        switch self {
        case .week: "Woche"
        case .month: "Monat"
        case .year: "Jahr"
        }
    }

    /// Überschrift des gezeigten Ausschnitts, z. B. „September 2026“.
    func title(for anchor: CalendarDate) -> String {
        let range = self.range(containing: anchor)
        switch self {
        case .week:
            let sameMonth = range.from.month == range.to.month
            return sameMonth
                ? "\(range.from.day).–\(range.to.day). \(CalendarDate.monthNames[range.to.month - 1]) \(range.to.year)"
                : "\(range.from.shortLabel) – \(range.to.shortLabel) \(range.to.year)"
        case .month:
            return "\(CalendarDate.monthNames[anchor.month - 1]) \(anchor.year)"
        case .year:
            return "\(range.from.shortLabel) \(range.from.year) – \(range.to.shortLabel) \(range.to.year)"
        }
    }
}
