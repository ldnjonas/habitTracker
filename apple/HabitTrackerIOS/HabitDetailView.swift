import SwiftUI
import HabitCore
import HabitUI

/// Alles über einen Habit: Kennzahlen, Jahresverlauf, Monat, Wochentage.
///
/// Wortgleich mit der Mac-Fassung, weil es dieselben Bausteine sind. Nur der
/// Jahresverlauf scrollt hier waagerecht: 53 Wochen auf 375 Punkten wären
/// Kacheln, die man nicht trifft.
struct HabitDetailView: View {
    @Environment(AppState.self) private var state
    var habit: Habit
    var onEdit: () -> Void

    @State private var month: CalendarDate = CalendarDate.today().monthStart
    /// Nur für Habits mit `tracksTime` geladen — es gibt keinen Grund, die
    /// Sitzungen aller Habits im Speicher zu halten.
    @State private var events: [EntryEvent] = []
    @State private var sessionDay: CalendarDate = CalendarDate.today()

    private var color: Color { Color(hex: habit.colorHex) }

    /// Ein Jahr plus Puffer, damit auch der längste Streak vollständig sichtbar ist.
    private var stats: HabitStats {
        state.stats(habit, from: state.today.adding(days: -400), to: state.today)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                kopf

                StatsPanel(stats: stats, color: color)

                if habit.tracksTime {
                    karte("Zeit") {
                        PeriodTotalPanel(
                            habit: habit,
                            total: state.periodTotal(habit,
                                                     from: state.today.adding(days: -83).weekStart,
                                                     to: state.today),
                            today: state.today)
                    }
                    karte("Sitzungen", trailing: { sitzungsNavigation }) {
                        SessionList(
                            habit: habit,
                            date: sessionDay,
                            sessions: HabitCore.sessions(of: habit, on: sessionDay, events: events),
                            onAdd: { start, end in
                                Task {
                                    await state.addSession(habitId: habit.id, start: start, end: end)
                                    await ladeEvents()
                                }
                            },
                            onDelete: { session in
                                Task {
                                    await state.deleteSession(habitId: habit.id, eventId: session.id)
                                    await ladeEvents()
                                }
                            })
                    }
                }

                karte("Jahresverlauf") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HeatmapView(habit: habit, days: stats.days, today: state.today) { date in
                            Task { await state.toggle(habit, on: date) }
                        }
                    }
                    .defaultScrollAnchor(.trailing)
                }

                karte(monatsTitel, trailing: { monatsNavigation }) {
                    MonthCalendarView(habit: habit, month: month,
                                      days: stats.days, today: state.today) { date in
                        Task { await state.toggle(habit, on: date) }
                    }
                }

                if !stats.weekdayBreakdown.isEmpty {
                    karte("Nach Wochentag") {
                        WeekdayBreakdownChart(breakdown: stats.weekdayBreakdown, color: color)
                    }
                }

                if habit.rules.count > 1 {
                    karte("Verlauf des Zeitplans") { regelVerlauf }
                }
            }
            .padding(16)
        }
        .navigationTitle(habit.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    HabitActions(
                        habit: habit,
                        onEdit: onEdit,
                        onArchive: { Task { await state.archive(habit) } },
                        onUnarchive: { Task { await state.unarchive(habit) } },
                        onDelete: { state.habitPendingDeletion = habit })
                } label: {
                    Label("Aktionen", systemImage: "ellipsis.circle")
                }
            }
        }
        .task { await ladeEvents() }
    }

    // MARK: - Kopf

    private var kopf: some View {
        HStack(spacing: 12) {
            Image(systemName: habit.symbol)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 44, height: 44)
                .background(color.opacity(0.15), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(habit.rule(on: state.today)?.schedule.label ?? "Ohne Zeitplan")
                    .font(.headline)
                if let notes = habit.notes, !notes.isEmpty {
                    Text(notes).font(.callout).foregroundStyle(.secondary)
                }
                if let archiviert = habit.archivedOn {
                    Text("Archiviert am \(archiviert.longLabel)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !habit.tagIds.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(habit.tagIds.compactMap(state.tag)) { TagChip(tag: $0) }
                    }
                }
            }
            Spacer()
        }
    }

    // MARK: - Karten

    private func karte<Inhalt: View, Rechts: View>(
        _ titel: String,
        @ViewBuilder trailing: () -> Rechts = { EmptyView() },
        @ViewBuilder content: () -> Inhalt
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(titel).font(.headline)
                Spacer()
                trailing()
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }

    private var monatsTitel: String {
        "\(CalendarDate.monthNames[month.month - 1]) \(month.year)"
    }

    private var monatsNavigation: some View {
        HStack(spacing: 4) {
            Button { month = month.addingMonths(-1) } label: { Image(systemName: "chevron.left") }
            Button { month = state.today.monthStart } label: { Text("Heute").font(.caption) }
            Button { month = month.addingMonths(1) } label: { Image(systemName: "chevron.right") }
                .disabled(month >= state.today.monthStart)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var sitzungsNavigation: some View {
        HStack(spacing: 4) {
            Button { sessionDay = sessionDay.adding(days: -1) } label: {
                Image(systemName: "chevron.left")
            }
            Button { sessionDay = state.today } label: { Text("Heute").font(.caption) }
            Button { sessionDay = sessionDay.adding(days: 1) } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(sessionDay >= state.today)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    /// Welche Regel ab wann galt — der Grund, warum ein alter Tag anders
    /// bewertet ist als ein neuer.
    private var regelVerlauf: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(habit.rules.reversed(), id: \.effectiveFrom) { rule in
                HStack(spacing: 8) {
                    Text("ab \(rule.effectiveFrom.longLabel)")
                        .font(.callout).foregroundStyle(.secondary)
                    Text(rule.schedule.label).font(.callout)
                    if let target = rule.target {
                        Text("· \(target.value.formatted()) \(target.unit)")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
        }
    }

    private func ladeEvents() async {
        guard habit.tracksTime else { events = []; return }
        events = (try? await state.api.events(habitId: habit.id,
                                              from: state.today.adding(days: -400),
                                              to: state.today)) ?? []
    }
}
