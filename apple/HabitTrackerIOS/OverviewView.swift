import SwiftUI
import HabitCore
import HabitUI

/// Alle Habits auf einen Blick — Woche, Monat oder Jahr.
///
/// Dieselben Bausteine wie auf dem Mac. Der eine Unterschied kommt vom Gerät:
/// **das Jahr scrollt waagerecht.** 53 Wochen auf 375 Punkten wären Kacheln von
/// sechs Punkten — man träfe sie nicht. Lieber scrollen als zielen; genauso ist
/// es in der WebApp entschieden.
struct OverviewView: View {
    @Environment(AppState.self) private var state

    @State private var scale: IntensityScale = .count
    @State private var selectedDay: CalendarDate?

    var body: some View {
        @Bindable var state = state

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let focus = state.activeFocus {
                    FocusBanner(progress: focus, today: state.today,
                                habitNames: focusHabitNames(focus)) {
                        Task { await state.abandonFocus(focus.run.id) }
                    }
                }

                OverviewStatsRow(stats: state.overviewStats, habitCount: state.habits.count)

                karte {
                    Picker("Ausschnitt", selection: $state.overviewSpan) {
                        ForEach(OverviewSpan.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    blaettern

                    diagramm

                    Picker("Sättigung nach", selection: $scale) {
                        ForEach(IntensityScale.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    Text(scale.explanation)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let selectedDay {
                    tagDetail(selectedDay)
                }

                if !state.dayLogs.isEmpty {
                    karte {
                        Text("Zusammenhänge").font(.headline)
                        CorrelationCard(
                            correlations: state.correlations,
                            habitName: { state.habit($0)?.name },
                            habitColor: { Color(hex: state.habit($0)?.colorHex ?? "#8E8E93") })
                    }
                }

                if state.habits.isEmpty {
                    ContentUnavailableView(
                        "Noch keine Habits", systemImage: "square.grid.3x3",
                        description: Text("Die Übersicht füllt sich, sobald du Habits angelegt und abgehakt hast."))
                        .padding(.top, 30)
                }
            }
            .padding(16)
        }
        .navigationTitle("Übersicht")
        .navigationBarTitleDisplayMode(.inline)
        .task { await state.ensureOverviewLoaded() }
        .onChange(of: state.overviewSpan) {
            // Ein anderer Ausschnitt kann Tage zeigen, die noch nicht geladen sind.
            selectedDay = nil
            Task { await state.ensureOverviewLoaded() }
        }
    }

    // MARK: - Bausteine

    private func karte<Inhalt: View>(@ViewBuilder _ inhalt: () -> Inhalt) -> some View {
        VStack(alignment: .leading, spacing: 12) { inhalt() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }

    private var blaettern: some View {
        HStack {
            Button {
                selectedDay = nil
                Task { await state.stepOverview(by: -1) }
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.bordered)

            Spacer()

            Button(state.overviewSpan.title(for: state.overviewAnchor)) {
                selectedDay = nil
                Task { await state.resetOverviewToToday() }
            }
            .font(.headline)
            .foregroundStyle(.primary)

            Spacer()

            Button {
                selectedDay = nil
                Task { await state.stepOverview(by: 1) }
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.bordered)
            .disabled(!state.canStepOverviewForward)
        }
    }

    @ViewBuilder
    private var diagramm: some View {
        let summaries = state.overviewSummaries

        switch state.overviewSpan {
        case .year:
            // Waagerecht scrollend und am rechten Rand beginnend: der jüngste
            // Tag interessiert zuerst.
            ScrollView(.horizontal, showsIndicators: false) {
                OverviewHeatmapView(
                    summaries: summaries,
                    today: state.today,
                    anchor: state.overviewAnchor,
                    scale: scale,
                    busiestDay: state.colorReference,
                    selected: selectedDay,
                    focusWindow: focusWindow,
                    exceptions: state.exceptionKindsByDay,
                    onSelect: waehle)
                .padding(.vertical, 4)
            }
            .defaultScrollAnchor(.trailing)

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
                onSelect: waehle)
        }
    }

    private func tagDetail(_ datum: CalendarDate) -> some View {
        let summary = state.overviewSummaries[datum]
        return karte {
            HStack(alignment: .firstTextBaseline) {
                Text(datum.longLabel).font(.headline)
                Spacer()
                if let summary, summary.scheduled > 0 {
                    Text("\(summary.completed) von \(summary.scheduled)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if let art = state.exceptionKindsByDay[datum] {
                Label(art.label, systemImage: "beach.umbrella")
                    .font(.callout).foregroundStyle(.secondary)
            }

            let habits = state.habits.filter { $0.isScheduled(on: datum) }
            if habits.isEmpty {
                Text("An diesem Tag war nichts geplant.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(habits) { habit in
                    HStack(spacing: 10) {
                        DayStatusDot(status: state.status(habit, on: datum),
                                     color: Color(hex: habit.colorHex))
                        Text(habit.name)
                        Spacer()
                        Text(state.status(habit, on: datum).label)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Button("Ausnahme für diesen Tag …") {
                state.exceptionEditorDate = datum
            }
            .font(.callout)
        }
    }

    private func waehle(_ datum: CalendarDate) {
        selectedDay = selectedDay == datum ? nil : datum
    }

    /// Der Zeitraum des laufenden Fokus, damit er im Bild wiederzufinden ist.
    private var focusWindow: ClosedRange<CalendarDate>? {
        state.activeFocus.map { $0.run.startsOn...$0.run.endsOn }
    }

    private func focusHabitNames(_ progress: FocusProgress) -> [String] {
        progress.run.habitIds.compactMap { state.habit($0)?.name }
    }
}
