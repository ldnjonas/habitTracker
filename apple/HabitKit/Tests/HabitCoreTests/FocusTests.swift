import Testing
import Foundation
@testable import HabitCore

private let today = CalendarDate(iso: "2026-09-04")!   // Freitag
private func d(_ iso: String) -> CalendarDate { CalendarDate(iso: iso)! }

private func habit(_ name: String, _ schedule: Schedule = .daily,
                   from: String = "2026-08-01") -> Habit {
    Habit(name: name, rules: [HabitRule(effectiveFrom: d(from), schedule: schedule)])
}

private func run(_ from: String, _ to: String,
                 habitIds: [UUID] = [], abandonedOn: String? = nil) -> FocusRun {
    FocusRun(startsOn: d(from), endsOn: d(to), habitIds: habitIds,
             abandonedOn: abandonedOn.map(d))
}

private func entries(_ habit: Habit, _ days: [String]) -> [Entry] {
    days.map { Entry(habitId: habit.id, date: d($0), value: 1) }
}

@Suite("Fokus: Auswertung")
struct FocusEvaluationTests {

    @Test("Lückenlos bis zum letzten Tag heißt durchgezogen")
    func completed() {
        let sport = habit("Sport")
        // Fokus vom 28.08. bis 03.09., alle sieben Tage erledigt.
        let done = ["2026-08-28", "2026-08-29", "2026-08-30",
                    "2026-08-31", "2026-09-01", "2026-09-02", "2026-09-03"]
        let progress = evaluate(run("2026-08-28", "2026-09-03"),
                                habits: [sport], entries: entries(sport, done), today: today)

        #expect(progress.outcome == .completed)
        #expect(progress.perfectDays == 7)
        #expect(progress.totalDays == 7)
        #expect(progress.fraction == 1.0)
    }

    @Test("Der erste vergangene Tag mit einer Lücke entscheidet")
    func failsOnFirstGap() {
        let sport = habit("Sport")
        let done = ["2026-08-28", "2026-08-29", "2026-09-01", "2026-09-02", "2026-09-03"]
        let progress = evaluate(run("2026-08-28", "2026-09-03"),
                                habits: [sport], entries: entries(sport, done), today: today)

        // Der 30.08. fehlt zuerst, nicht der 31.08.
        #expect(progress.outcome == .failed(on: d("2026-08-30")))
        #expect(progress.perfectDays == 5)
    }

    @Test("Der laufende Tag lässt den Fokus nicht scheitern")
    func todayDoesNotFail() {
        let sport = habit("Sport")
        // Fokus 02.–08.09., heute (04.09.) noch nichts erledigt.
        let progress = evaluate(run("2026-09-02", "2026-09-08"),
                                habits: [sport],
                                entries: entries(sport, ["2026-09-02", "2026-09-03"]),
                                today: today)

        #expect(progress.outcome == .running(dayNumber: 3, totalDays: 7))
        #expect(progress.elapsedDays == 3)
        #expect(progress.perfectDays == 2)
    }

    @Test("Ein Fokus, der erst beginnt, steht auf ausstehend")
    func upcoming() {
        let sport = habit("Sport")
        let progress = evaluate(run("2026-09-07", "2026-09-13"),
                                habits: [sport], entries: [], today: today)
        #expect(progress.outcome == .upcoming)
        #expect(progress.elapsedDays == 0)
    }

    /// Ohne diese Regel müsste man bis Mitternacht warten, um zu erfahren,
    /// ob man es geschafft hat.
    @Test("Am letzten Tag steht das Ergebnis, sobald er vollständig ist")
    func lastDayCompletesImmediately() {
        let sport = habit("Sport")
        let done = ["2026-09-02", "2026-09-03", "2026-09-04"]
        let progress = evaluate(run("2026-09-02", "2026-09-04"),
                                habits: [sport], entries: entries(sport, done), today: today)
        #expect(progress.outcome == .completed)
    }

    @Test("Am letzten Tag mit offener Aufgabe läuft er noch")
    func lastDayStillOpen() {
        let sport = habit("Sport")
        let progress = evaluate(run("2026-09-02", "2026-09-04"),
                                habits: [sport],
                                entries: entries(sport, ["2026-09-02", "2026-09-03"]),
                                today: today)
        #expect(progress.outcome == .running(dayNumber: 3, totalDays: 3))
    }

    @Test("Selbst beendet schlägt jedes andere Ergebnis")
    func abandonedWins() {
        let sport = habit("Sport")
        // Rechnerisch wäre der Lauf noch heil.
        let done = ["2026-09-02", "2026-09-03"]
        let progress = evaluate(run("2026-09-02", "2026-09-08", abandonedOn: "2026-09-03"),
                                habits: [sport], entries: entries(sport, done), today: today)
        #expect(progress.outcome == .abandoned(on: d("2026-09-03")))
    }

    @Test("Ein Fokus deckt nur seine eigenen Habits ab")
    func onlySelectedHabits() {
        let sport = habit("Sport")
        let lesen = habit("Lesen")
        // Nur Sport ist Teil des Laufs; „Lesen" wurde nie erledigt.
        let progress = evaluate(run("2026-09-02", "2026-09-03", habitIds: [sport.id]),
                                habits: [sport, lesen],
                                entries: entries(sport, ["2026-09-02", "2026-09-03"]),
                                today: today)
        #expect(progress.outcome == .completed)

        // Ohne Auswahl zählen alle — und dann reißt „Lesen" den Lauf.
        let all = evaluate(run("2026-09-02", "2026-09-03"),
                           habits: [sport, lesen],
                           entries: entries(sport, ["2026-09-02", "2026-09-03"]),
                           today: today)
        #expect(all.outcome == .failed(on: d("2026-09-02")))
    }

    @Test("Ein Tag ohne Plan bricht den Fokus nicht")
    func emptyDayIsHarmless() {
        // Nur Mo/Mi/Fr — Dienstag und Donnerstag stand nichts an.
        let sport = habit("Sport", .weekdays([.monday, .wednesday, .friday]))
        let progress = evaluate(run("2026-08-31", "2026-09-03"),
                                habits: [sport],
                                entries: entries(sport, ["2026-08-31", "2026-09-02"]),
                                today: today)
        #expect(progress.outcome == .completed)
        #expect(progress.perfectDays == 2, "nur die zwei geplanten Tage zählen")
        // Der Nenner darf die geschenkten Tage nicht mitzählen, sonst stünde
        // neben „durchgezogen“ ein „2 von 4“.
        #expect(progress.plannedDays == 2)
        #expect(progress.fraction == 1.0)
    }

    @Test("Urlaub nimmt den Tag heraus, ein Freeze rettet ihn nicht")
    func exceptionsFollowOverviewRules() {
        let sport = habit("Sport")
        let urlaub = evaluate(
            run("2026-09-01", "2026-09-03"), habits: [sport],
            entries: entries(sport, ["2026-09-01", "2026-09-03"]),
            exceptions: [DayException(habitId: sport.id, date: d("2026-09-02"), kind: .paused)],
            today: today)
        #expect(urlaub.outcome == .completed)

        // Ein Freeze rettet den Streak, aber nicht den Fokus — er ist das
        // strengere Versprechen.
        let freeze = evaluate(
            run("2026-09-01", "2026-09-03"), habits: [sport],
            entries: entries(sport, ["2026-09-01", "2026-09-03"]),
            exceptions: [DayException(habitId: sport.id, date: d("2026-09-02"), kind: .frozen)],
            today: today)
        #expect(freeze.outcome == .failed(on: d("2026-09-02")))
    }

    @Test("Ein Fokus ohne einen einzigen geplanten Tag gilt als geschafft")
    func nothingPlannedAtAll() {
        // Der Habit beginnt erst nach dem Fokusfenster.
        let sport = habit("Sport", from: "2026-09-10")
        let progress = evaluate(run("2026-09-01", "2026-09-03"),
                                habits: [sport], entries: [], today: today)
        #expect(progress.outcome == .completed)
        #expect(progress.perfectDays == 0)
        #expect(progress.plannedDays == 0)
        #expect(progress.fraction == 1.0, "nichts zu tun heißt vollständig, nicht leer")
    }

    @Test("Künftige Tage zählen noch nicht in den Nenner")
    func plannedDaysStopsAtToday() {
        let sport = habit("Sport")
        // Fokus 02.–08.09., heute ist der 04.09.
        let progress = evaluate(run("2026-09-02", "2026-09-08"),
                                habits: [sport],
                                entries: entries(sport, ["2026-09-02", "2026-09-03"]),
                                today: today)
        #expect(progress.plannedDays == 3, "der 05.–08.09. steht noch aus")
        #expect(progress.perfectDays == 2)
    }
}

@Suite("Fokus: Bilanz")
struct FocusRecordTests {

    @Test("Nur abgeschlossene Läufe zählen")
    func onlyFinishedCount() {
        let result = record(of: [.completed, .failed(on: today), .running(dayNumber: 2, totalDays: 7),
                                 .upcoming, .abandoned(on: today)])
        #expect(result.completed == 1)
        #expect(result.failed == 1)
        #expect(result.abandoned == 1)
        #expect(result.finished == 3)
        #expect(result.successRate == 1.0 / 3.0)
    }

    @Test("Ohne abgeschlossenen Lauf gibt es keine Quote")
    func noRateWithoutFinished() {
        #expect(record(of: [.running(dayNumber: 1, totalDays: 7)]).successRate == nil)
        #expect(record(of: []).successRate == nil)
    }

    @Test("Die Siegesserie zählt nur unmittelbar aufeinander folgende Erfolge")
    func winStreak() {
        let result = record(of: [.completed, .completed, .failed(on: today),
                                 .completed, .completed, .completed])
        #expect(result.longestWinStreak == 3)
    }

    @Test("Ein laufender Lauf unterbricht die Serie nicht")
    func openRunDoesNotBreakStreak() {
        let result = record(of: [.completed, .running(dayNumber: 1, totalDays: 7), .completed])
        #expect(result.longestWinStreak == 2)
    }
}
