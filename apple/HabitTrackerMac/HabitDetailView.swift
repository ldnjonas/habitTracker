import SwiftUI
import HabitCore
import HabitUI

/// Alles über einen Habit: Kennzahlen, Jahresverlauf, Monat, Wochentage.
struct HabitDetailView: View {
    @Environment(AppState.self) private var state
    var habit: Habit
    var onEdit: () -> Void

    @State private var month: CalendarDate = CalendarDate.today().monthStart

    private var color: Color { Color(hex: habit.colorHex) }

    /// Ein Jahr plus Puffer, damit auch der längste Streak vollständig sichtbar ist.
    private var stats: HabitStats {
        state.stats(habit, from: state.today.adding(days: -400), to: state.today)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                StatsPanel(stats: stats, color: color)

                card("Jahresverlauf") {
                    HeatmapView(habit: habit, days: stats.days, today: state.today) { date in
                        Task { await state.toggle(habit, on: date) }
                    }
                }

                card(monthTitle, trailing: { monthNavigation }) {
                    MonthCalendarView(habit: habit, month: month,
                                      days: stats.days, today: state.today) { date in
                        Task { await state.toggle(habit, on: date) }
                    }
                }

                if !stats.weekdayBreakdown.isEmpty {
                    card("Nach Wochentag") {
                        WeekdayBreakdownChart(breakdown: stats.weekdayBreakdown, color: color)
                    }
                }

                if habit.rules.count > 1 {
                    card("Verlauf des Zeitplans") { ruleHistory }
                }
            }
            .padding(20)
        }
        .navigationTitle(habit.name)
        .toolbar {
            Button("Bearbeiten …", action: onEdit)
            // Ohne das müsste man für jede andere Aktion zurück in die Liste.
            HabitMenuButton(
                habit: habit,
                onEdit: onEdit,
                onArchive: { Task { await state.archive(habit) } },
                onUnarchive: { Task { await state.unarchive(habit) } },
                onDelete: { state.habitPendingDeletion = habit })
        }
    }

    // MARK: - Kopf

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: habit.symbol)
                .font(.system(size: 22))
                .foregroundStyle(color)
                .frame(width: 46, height: 46)
                .background(color.opacity(0.15), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(habit.name).font(.title3.weight(.semibold))
                HStack(spacing: 6) {
                    Text(habit.rule(on: state.today)?.schedule.label ?? "")
                    if let target = habit.target(on: state.today) {
                        Text("·")
                        Text(target.comparison == .atLeast
                             ? "mindestens \(number(target.value)) \(target.unit)"
                             : "höchstens \(number(target.value)) \(target.unit)")
                    }
                    if let time = habit.timeOfDay {
                        Text("·")
                        Label(time.label, systemImage: time.symbolName)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()
            if let trend = state.trend(habit) { TrendBadge(trend: trend) }
        }
    }

    // MARK: - Monatsnavigation

    private var monthTitle: String {
        "\(CalendarDate.monthNames[month.month - 1]) \(month.year)"
    }

    private var monthNavigation: some View {
        HStack(spacing: 2) {
            Button { month = month.monthStart.adding(days: -1).monthStart } label: {
                Image(systemName: "chevron.left")
            }
            Button { month = month.monthEnd.adding(days: 1) } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(month.monthEnd >= state.today)
        }
        .buttonStyle(.borderless)
    }

    /// Macht die Versionierung sichtbar — sonst wundert man sich, warum ein
    /// alter Tag anders bewertet wird als ein neuer.
    private var ruleHistory: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(habit.rules.reversed(), id: \.effectiveFrom) { rule in
                HStack {
                    Text("ab \(rule.effectiveFrom.longLabel)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 150, alignment: .leading)
                    Text(rule.schedule.label)
                    if let target = rule.target {
                        Text("· \(number(target.value)) \(target.unit)")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .font(.callout)
            }
        }
    }

    // MARK: - Rahmen

    private func card<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        card(title, trailing: { EmptyView() }, content: content)
    }

    private func card<Content: View, Trailing: View>(
        _ title: String,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                trailing()
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }
}
