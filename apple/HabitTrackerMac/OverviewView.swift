import SwiftUI
import HabitCore
import HabitUI

/// Alle Habits auf einen Blick — wahlweise als Woche, Monat oder Jahr.
///
/// Die Einzel-Heatmap im Habit-Detail beantwortet „halte ich *das* durch?“,
/// diese Seite „wie laufen meine Tage insgesamt?“ — deshalb eine eigene Seite
/// und keine weitere Kachel in der Detailansicht.
struct OverviewView: View {
    @Environment(AppState.self) private var state

    @State private var scale: IntensityScale = .count
    @State private var selectedDay: CalendarDate?

    var body: some View {
        @Bindable var state = state

        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                let stats = state.overviewStats

                if let focus = state.activeFocus {
                    FocusBanner(progress: focus, today: state.today,
                                habitNames: focusHabitNames(focus)) {
                        Task { await state.abandonFocus(focus.run.id) }
                    }
                }

                OverviewStatsRow(stats: stats, habitCount: state.habits.count)

                VStack(alignment: .leading, spacing: 12) {
                    header($state)
                    chart
                }
                .padding(16)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))

                if let selectedDay {
                    dayDetail(selectedDay)
                }

                if !state.dayLogs.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Zusammenhänge").font(.headline)
                        CorrelationCard(
                            correlations: state.correlations,
                            habitName: { state.habit($0)?.name },
                            habitColor: { Color(hex: state.habit($0)?.colorHex ?? "#8E8E93") })
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                }

                if state.habits.isEmpty {
                    ContentUnavailableView(
                        "Noch keine Habits", systemImage: "square.grid.3x3",
                        description: Text("Die Übersicht füllt sich, sobald du Habits angelegt und abgehakt hast."))
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                }
            }
            // Begrenzt, damit die Karten auf einem breiten Bildschirm nicht
            // auseinanderlaufen — die Jahres-Heatmap braucht rund 760 Punkte.
            .frame(maxWidth: 1080, alignment: .leading)
            .padding(20)
            .animation(.easeInOut(duration: 0.15), value: selectedDay)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .navigationTitle("Übersicht")
        .task { await state.ensureOverviewLoaded() }
        .onChange(of: state.overviewSpan) {
            // Ein anderer Ausschnitt kann Tage zeigen, die noch nicht geladen sind.
            selectedDay = nil
            Task { await state.ensureOverviewLoaded() }
        }
    }

    // MARK: - Kopfzeile

    private func header(_ state: Bindable<AppState>) -> some View {
        HStack(spacing: 12) {
            Picker("Ausschnitt", selection: state.overviewSpan) {
                ForEach(OverviewSpan.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 200)

            navigation

            Spacer()

            Picker("Sättigung nach", selection: $scale) {
                ForEach(IntensityScale.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 150)
            .help(scale.explanation)
        }
    }

    private var navigation: some View {
        HStack(spacing: 6) {
            Button {
                selectedDay = nil
                Task { await state.stepOverview(by: -1) }
            } label: {
                Image(systemName: "chevron.left")
            }
            .help("Zurück")

            Text(state.overviewSpan.title(for: state.overviewAnchor))
                .font(.headline)
                .frame(minWidth: 190)

            Button {
                selectedDay = nil
                Task { await state.stepOverview(by: 1) }
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!state.canStepOverviewForward)
            .help("Vorwärts")

            Button("Heute") {
                selectedDay = nil
                Task { await state.resetOverviewToToday() }
            }
            .disabled(!state.canStepOverviewForward && state.overviewAnchor == state.today)
        }
        .buttonStyle(.bordered)
    }

    // MARK: - Darstellung

    @ViewBuilder
    private var chart: some View {
        let summaries = state.overviewSummaries

        switch state.overviewSpan {
        case .year:
            OverviewHeatmapView(
                summaries: summaries,
                today: state.today,
                anchor: state.overviewAnchor,
                scale: scale,
                busiestDay: state.colorReference,
                selected: selectedDay,
                focusWindow: focusWindow,
                exceptions: state.exceptionKindsByDay,
                onSelect: select)
            .padding(.vertical, 4)

        case .week, .month:
            OverviewCalendarGrid(
                summaries: summaries,
                span: state.overviewSpan,
                range: state.overviewRange,
                today: state.today,
                scale: scale,
                busiestDay: state.colorReference,
                selected: selectedDay,
                focusWindow: focusWindow,
                exceptions: state.exceptionKindsByDay,
                onSelect: select)
        }
    }

    private func hasContent(_ log: DayLog) -> Bool {
        log.mood != nil || log.energy != nil || log.sleepHours != nil || log.note != nil
    }

    private func journalRow(_ log: DayLog) -> some View {
        HStack(spacing: 14) {
            if let mood = log.mood {
                Label("\(mood)/5", systemImage: "face.smiling")
            }
            if let energy = log.energy {
                Label("\(energy)/5", systemImage: "bolt.fill")
            }
            if let schlaf = log.sleepHours {
                Label(formatMinutes(schlaf * 60), systemImage: "bed.double.fill")
            }
            if let note = log.note {
                Text(note).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
        .font(.callout)
        .monospacedDigit()
    }

    /// Der Zeitraum des laufenden Fokus, damit er im Bild wiederzufinden ist.
    private var focusWindow: ClosedRange<CalendarDate>? {
        state.activeFocus.map { $0.run.startsOn...$0.run.endsOn }
    }

    private func focusHabitNames(_ progress: FocusProgress) -> [String] {
        progress.run.habitIds.compactMap { id in
            state.habits.first { $0.id == id }?.name
        }
    }

    /// Nochmal auf denselben Tag klappt die Detailzeile wieder zu.
    private func select(_ date: CalendarDate) {
        selectedDay = (selectedDay == date) ? nil : date
    }

    // MARK: - Tagesdetail

    @ViewBuilder
    private func dayDetail(_ date: CalendarDate) -> some View {
        let breakdown = state.dayBreakdown(on: date)
        let summary = state.overviewSummaries[date]

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(date.longLabel).font(.headline)
                if let summary, summary.scheduled > 0 {
                    Text("\(summary.completed) von \(summary.scheduled)")
                        .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                Button {
                    selectedDay = nil
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Schließen")
            }

            let exceptions = state.exceptions(on: date)
            if !exceptions.isEmpty {
                ForEach(exceptions) { exception in
                    HStack(spacing: 8) {
                        Image(systemName: DayStatus.excepted(exception.kind).symbolName ?? "circle")
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                        Text(exception.kind.label)
                        if let reason = exception.reason {
                            Text("· \(reason)").foregroundStyle(.secondary)
                        }
                        Text(exception.habitId == nil
                             ? "· alle Habits"
                             : "· \(state.habit(exception.habitId!)?.name ?? "ein Habit")")
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .font(.callout)
                }
                Divider()
            }

            if breakdown.isEmpty {
                Text("An diesem Tag stand nichts an.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(breakdown, id: \.habit.id) { item in
                    HStack(spacing: 8) {
                        DayStatusDot(status: item.status,
                                     color: Color(hex: item.habit.colorHex), size: 12)
                        Image(systemName: item.habit.symbol)
                            .foregroundStyle(Color(hex: item.habit.colorHex))
                            .frame(width: 16)
                        Text(item.habit.name)
                        Spacer()
                        if state.canFreeze(item.habit, on: date) {
                            Button {
                                Task { await state.applyFreeze(item.habit, on: date) }
                            } label: {
                                Label("Retten", systemImage: "snowflake")
                            }
                            .controlSize(.small)
                            .help("Einen Streak Freeze einlösen — der Streak hält, die Quote bleibt ehrlich (\(state.freezeBalance) übrig)")
                        }
                        Text(item.status.label)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Divider()

            if let log = state.dayLog(on: date), hasContent(log) {
                journalRow(log)
            }

            HStack {
                Button(state.dayLog(on: date) == nil ? "Journal …" : "Journal bearbeiten …") {
                    state.dayLogEditorDate = date
                }
                Button("Ausnahme eintragen …") { state.exceptionEditorDate = date }
                if !state.exceptions(on: date).isEmpty {
                    Button("Ausnahme aufheben", role: .destructive) {
                        Task { await state.removeExceptions(on: date) }
                    }
                }
                Spacer()
            }
            .controlSize(.small)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }
}
