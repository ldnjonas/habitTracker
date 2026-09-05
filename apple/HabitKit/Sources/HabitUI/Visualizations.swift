import SwiftUI
import HabitCore

// MARK: - Jahres-Heatmap

/// 53 Wochen als Spalten, sieben Wochentage als Zeilen.
///
/// Bewusst aus einzelnen Views statt aus einem `Canvas` gezeichnet: 371 kleine
/// Rechtecke sind für SwiftUI unkritisch, und nur so ist jeder Tag anklickbar
/// und kann einen Tooltip tragen.
public struct HeatmapView: View {
    public var habit: Habit
    public var days: [CalendarDate: DayStatus]
    public var today: CalendarDate
    public var weeks: Int
    public var onSelect: ((CalendarDate) -> Void)?

    private let cell: CGFloat = 11
    private let gap: CGFloat = 3

    public init(
        habit: Habit,
        days: [CalendarDate: DayStatus],
        today: CalendarDate,
        weeks: Int = 53,
        onSelect: ((CalendarDate) -> Void)? = nil
    ) {
        self.habit = habit
        self.days = days
        self.today = today
        self.weeks = weeks
        self.onSelect = onSelect
    }

    private var color: Color { Color(hex: habit.colorHex) }

    /// Montag der ersten angezeigten Woche.
    private var start: CalendarDate {
        today.weekStart.adding(days: -7 * (weeks - 1))
    }

    private var weekStarts: [CalendarDate] {
        (0..<weeks).map { start.adding(days: 7 * $0) }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            monthLabels
            HStack(alignment: .top, spacing: gap) {
                weekdayLabels
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: gap) {
                            ForEach(weekStarts, id: \.self) { weekStart in
                                column(weekStart)
                                    .id(weekStart)
                            }
                        }
                    }
                    .onAppear {
                        // Die aktuelle Woche ist die interessante — dorthin scrollen.
                        proxy.scrollTo(today.weekStart, anchor: .trailing)
                    }
                }
            }
        }
    }

    private func column(_ weekStart: CalendarDate) -> some View {
        VStack(spacing: gap) {
            ForEach(0..<7, id: \.self) { offset in
                let date = weekStart.adding(days: offset)
                let status = days[date] ?? (date > today ? .future : .notScheduled)
                DayStatusDot(status: status, color: color, size: cell)
                    .help("\(date.longLabel) — \(status.label)")
                    .onTapGesture { onSelect?(date) }
            }
        }
    }

    private var weekdayLabels: some View {
        VStack(spacing: gap) {
            ForEach(Weekday.allCases, id: \.self) { weekday in
                // Nur jeden zweiten beschriften, sonst wird die Spalte zur Wand.
                Text(weekday.rawValue % 2 == 1 ? weekday.shortLabel : "")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: cell, alignment: .trailing)
            }
        }
    }

    /// Monatsnamen über der jeweils ersten Woche eines Monats.
    private var monthLabels: some View {
        HStack(spacing: gap) {
            Color.clear.frame(width: 18, height: 10)
            ForEach(weekStarts, id: \.self) { weekStart in
                Text(isFirstWeekOfMonth(weekStart)
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

    private func isFirstWeekOfMonth(_ weekStart: CalendarDate) -> Bool {
        weekStart.day <= 7
    }
}

// MARK: - Monatskalender

/// Klassischer Monatsraster — besser zum Nachtragen als die Jahres-Heatmap.
public struct MonthCalendarView: View {
    public var habit: Habit
    public var month: CalendarDate
    public var days: [CalendarDate: DayStatus]
    public var today: CalendarDate
    public var onSelect: ((CalendarDate) -> Void)?

    public init(
        habit: Habit,
        month: CalendarDate,
        days: [CalendarDate: DayStatus],
        today: CalendarDate,
        onSelect: ((CalendarDate) -> Void)? = nil
    ) {
        self.habit = habit
        self.month = month
        self.days = days
        self.today = today
        self.onSelect = onSelect
    }

    private var color: Color { Color(hex: habit.colorHex) }

    public var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                ForEach(Weekday.allCases, id: \.self) { weekday in
                    Text(weekday.shortLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7),
                      spacing: 4) {
                // Führende Leerfelder, damit der Erste im richtigen Wochentag steht.
                ForEach(0..<(month.monthStart.weekday.rawValue - 1), id: \.self) { _ in
                    Color.clear.frame(height: 30)
                }
                ForEach(month.monthStart.through(month.monthEnd), id: \.self) { date in
                    cell(date)
                }
            }
        }
    }

    private func cell(_ date: CalendarDate) -> some View {
        let status = days[date] ?? (date > today ? .future : .notScheduled)
        return ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(status.fillOpacity() > 0
                      ? color.opacity(status.fillOpacity())
                      : Color.secondary.opacity(0.08))
            if case .missed = status {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1)
            }
            if date == today {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(color, lineWidth: 2)
            }
            Text("\(date.day)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(status.isCompleted ? .white : .primary)
        }
        .frame(height: 30)
        .help("\(date.longLabel) — \(status.label)")
        .onTapGesture { onSelect?(date) }
    }
}

// MARK: - Wochentage

/// Zeigt, an welchem Wochentag es regelmäßig scheitert.
public struct WeekdayBreakdownChart: View {
    public var breakdown: [Weekday: Double]
    public var color: Color

    public init(breakdown: [Weekday: Double], color: Color) {
        self.breakdown = breakdown
        self.color = color
    }

    /// Der schwächste Wochentag — nur nennenswert, wenn es auch einen guten gibt.
    private var weakest: Weekday? {
        guard breakdown.count >= 2,
              let min = breakdown.min(by: { $0.value < $1.value }),
              let max = breakdown.max(by: { $0.value < $1.value }),
              max.value - min.value > 0.2
        else { return nil }
        return min.key
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(Weekday.allCases, id: \.self) { weekday in
                    VStack(spacing: 4) {
                        GeometryReader { geo in
                            let share = breakdown[weekday] ?? 0
                            VStack {
                                Spacer(minLength: 0)
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(weekday == weakest ? Color.orange : color)
                                    .frame(height: max(2, geo.size.height * share))
                            }
                        }
                        .frame(height: 44)
                        Text(weekday.shortLabel)
                            .font(.system(size: 9))
                            .foregroundStyle(weekday == weakest ? .orange : .secondary)
                    }
                }
            }
            if let weakest {
                Text("Schwächster Tag: \(weakest.shortLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Kennzahlen

public struct StatsPanel: View {
    public var stats: HabitStats
    public var color: Color

    public init(stats: HabitStats, color: Color) {
        self.stats = stats
        self.color = color
    }

    private var unitLabel: String {
        stats.streakUnit == .weeks ? "Wochen" : "Tage"
    }

    public var body: some View {
        HStack(spacing: 20) {
            metric("Aktuell", "\(stats.currentStreak)", unitLabel, tint: color)
            metric("Längster", "\(stats.longestStreak)", unitLabel)
            metric("Quote", percent(stats.completionRate),
                   "\(stats.completedCount) von \(stats.evaluatedCount)")
        }
    }

    private func metric(_ title: String, _ value: String, _ caption: String,
                        tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.semibold).monospacedDigit())
                .foregroundStyle(tint ?? .primary)
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
