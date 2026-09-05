import SwiftUI
import HabitCore

public extension IntensityScale {
    var label: String {
        switch self {
        case .count: "Anzahl"
        case .share: "Anteil"
        }
    }

    var explanation: String {
        switch self {
        case .count:
            "Je mehr Habits an einem Tag erledigt wurden, desto kräftiger die Farbe."
        case .share:
            "Je größer der erledigte Anteil des Tagespensums, desto kräftiger die Farbe."
        }
    }
}

/// Jahres-Heatmap über **alle** Habits zusammen.
///
/// Anders als `HeatmapView`, die einen einzelnen Habit in dessen Farbe zeigt,
/// trägt diese Ansicht eine einzige Farbe in fünf Stufen — sonst würde die
/// Fläche zum Farbkasten und die Aussage ginge verloren.
///
/// Die beiden Maßstäbe beantworten verschiedene Fragen und sind beide sinnvoll:
/// **Anzahl** zeigt Betriebsamkeit (ein Sonntag mit einem Habit bleibt blass),
/// **Anteil** zeigt Verlässlichkeit (derselbe Sonntag leuchtet, wenn dieser eine
/// Habit erledigt wurde). Deshalb umschaltbar statt vorgeschrieben.
public struct OverviewHeatmapView: View {
    public var summaries: [CalendarDate: DaySummary]
    public var today: CalendarDate
    /// Der Tag, um den herum der Ausschnitt liegt — beim Blättern nicht `today`.
    public var anchor: CalendarDate
    public var scale: IntensityScale
    /// Bezugsgröße für `.count` — üblicherweise `OverviewStats.busiestDay`.
    public var busiestDay: Int
    public var tint: Color
    public var selected: CalendarDate?
    public var onSelect: ((CalendarDate) -> Void)?

    private let cell: CGFloat = 11
    private let gap: CGFloat = 3
    private let weeks: Int

    public init(
        summaries: [CalendarDate: DaySummary],
        today: CalendarDate,
        anchor: CalendarDate? = nil,
        scale: IntensityScale = .count,
        busiestDay: Int,
        weeks: Int = 53,
        tint: Color = .accentColor,
        selected: CalendarDate? = nil,
        onSelect: ((CalendarDate) -> Void)? = nil
    ) {
        self.summaries = summaries
        self.today = today
        self.anchor = anchor ?? today
        self.scale = scale
        self.busiestDay = busiestDay
        self.weeks = weeks
        self.tint = tint
        self.selected = selected
        self.onSelect = onSelect
    }

    private var start: CalendarDate { anchor.weekStart.adding(days: -7 * (weeks - 1)) }
    private var weekStarts: [CalendarDate] { (0..<weeks).map { start.adding(days: 7 * $0) } }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            monthLabels
            HStack(alignment: .top, spacing: gap) {
                weekdayLabels
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: gap) {
                            ForEach(weekStarts, id: \.self) { column($0).id($0) }
                        }
                        .padding(.vertical, 2)   // Platz für den Auswahlrahmen
                    }
                    // Die letzte Woche des Ausschnitts ist die interessante.
                    .onAppear { proxy.scrollTo(self.anchor.weekStart, anchor: .trailing) }
                    .onChange(of: self.anchor) {
                        proxy.scrollTo(self.anchor.weekStart, anchor: .trailing)
                    }
                }
            }
            legend
        }
    }

    private func column(_ weekStart: CalendarDate) -> some View {
        VStack(spacing: gap) {
            ForEach(0..<7, id: \.self) { offset in
                let date = weekStart.adding(days: offset)
                cellView(date)
            }
        }
    }

    @ViewBuilder
    private func cellView(_ date: CalendarDate) -> some View {
        let summary = summaries[date]
        let isFuture = date > today

        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
            .fill(fill(summary, isFuture: isFuture))
            .frame(width: cell, height: cell)
            .overlay {
                if date == selected {
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .strokeBorder(Color.primary, lineWidth: 1.5)
                } else if date == today {
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.45), lineWidth: 1)
                }
            }
            .help(tooltip(date, summary, isFuture: isFuture))
            .onTapGesture { onSelect?(date) }
    }

    private func fill(_ summary: DaySummary?, isFuture: Bool) -> Color {
        guard !isFuture, let summary, summary.completed > 0 else {
            return Color.secondary.opacity(isFuture ? 0.06 : 0.12)
        }
        return tint.opacity(OverviewHeatmapView.opacity(for: level(summary)))
    }

    private func level(_ summary: DaySummary) -> Int {
        HabitCore.intensityLevel(summary, scale: scale, busiestDay: busiestDay)
    }

    /// Deckkraft je Stufe. Fünf Stufen wie beim Vorbild: keine, dann vier
    /// Abstufungen — mehr unterscheidet das Auge in einem 11-Punkt-Quadrat nicht.
    static func opacity(for level: Int) -> Double {
        [0, 0.25, 0.45, 0.7, 1.0][min(4, max(0, level))]
    }

    private func tooltip(_ date: CalendarDate, _ summary: DaySummary?, isFuture: Bool) -> String {
        guard !isFuture else { return date.longLabel }
        guard let summary, summary.scheduled > 0 else {
            return "\(date.longLabel) — nichts geplant"
        }
        let base = "\(date.longLabel) — \(summary.completed) von \(summary.scheduled) erledigt"
        return summary.isPerfect ? base + " ✓" : base
    }

    private var weekdayLabels: some View {
        VStack(spacing: gap) {
            ForEach(Weekday.allCases, id: \.self) { weekday in
                Text(weekday.rawValue % 2 == 1 ? weekday.shortLabel : "")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: cell, alignment: .trailing)
            }
        }
    }

    private var monthLabels: some View {
        HStack(spacing: gap) {
            Color.clear.frame(width: 18, height: 10)
            ForEach(weekStarts, id: \.self) { weekStart in
                Text(weekStart.day <= 7
                     ? String(CalendarDate.monthNames[weekStart.month - 1].prefix(3))
                     : "")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                    // Erst den Text unzerbrechlich machen, dann rahmen: ein
                    // `.fixedSize()` *nach* dem Rahmen fixiert diesen und lässt
                    // den Text trotzdem umbrechen („Se/p" statt „Sep").
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(width: cell, alignment: .leading)
            }
        }
        .clipped()
    }

    private var legend: some View {
        HStack(spacing: 4) {
            Spacer()
            Text("weniger").font(.system(size: 9)).foregroundStyle(.secondary)
            ForEach(0...4, id: \.self) { level in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(level == 0
                          ? Color.secondary.opacity(0.12)
                          : tint.opacity(OverviewHeatmapView.opacity(for: level)))
                    .frame(width: 9, height: 9)
            }
            Text("mehr").font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .help(scale.explanation)
    }
}

// MARK: - Kennzahlen

/// Die Zahlenreihe über der Übersichts-Heatmap.
public struct OverviewStatsRow: View {
    public var stats: OverviewStats
    public var habitCount: Int

    public init(stats: OverviewStats, habitCount: Int) {
        self.stats = stats
        self.habitCount = habitCount
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 28) {
            metric("\(stats.perfectStreak)",
                   stats.perfectStreak == 1 ? "Tag am Stück perfekt" : "Tage am Stück perfekt",
                   help: "Aufeinanderfolgende Tage, an denen alles Anstehende erledigt war. Tage ohne Plan unterbrechen nicht.")
            metric("\(stats.perfectDays)",
                   stats.perfectDays == 1 ? "perfekter Tag" : "perfekte Tage",
                   help: "Von \(stats.daysWithPlan) \(stats.daysWithPlan == 1 ? "Tag" : "Tagen") mit Plan im gezeigten Zeitraum.")
            metric("\(stats.totalCompletions)",
                   stats.totalCompletions == 1 ? "Erledigung" : "Erledigungen",
                   help: "Alle erledigten Habit-Tage zusammen.")
            metric("\(habitCount)", habitCount == 1 ? "Habit" : "Habits", help: nil)
            Spacer()
        }
    }

    private func metric(_ value: String, _ caption: String, help: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title2).monospacedDigit()
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
        .help(help ?? "")
    }
}
