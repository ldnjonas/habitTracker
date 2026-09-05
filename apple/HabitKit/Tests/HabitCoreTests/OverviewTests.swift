import Testing
import Foundation
@testable import HabitCore

private let today = CalendarDate(iso: "2026-09-04")!   // Freitag
private func d(_ iso: String) -> CalendarDate { CalendarDate(iso: iso)! }

private func habit(
    _ name: String,
    _ schedule: Schedule,
    kind: HabitKind = .binary,
    from: String = "2026-08-01"
) -> Habit {
    Habit(name: name, kind: kind,
          rules: [HabitRule(effectiveFrom: d(from), schedule: schedule)])
}

private func entry(_ habit: Habit, _ iso: String, _ value: Double = 1) -> Entry {
    Entry(habitId: habit.id, date: d(iso), value: value)
}

@Suite("Gesamtübersicht")
struct OverviewTests {

    @Test("Zwei tägliche Habits, einer erledigt")
    func simpleShare() {
        let sport = habit("Sport", .daily)
        let lesen = habit("Lesen", .daily)
        let result = overview(habits: [sport, lesen],
                              entries: [entry(sport, "2026-09-03")],
                              from: d("2026-09-03"), to: d("2026-09-03"), today: today)

        let day = result[d("2026-09-03")]!
        #expect(day.completed == 1)
        #expect(day.scheduled == 2)
        #expect(day.share == 0.5)
        #expect(!day.isPerfect)
    }

    /// Der Kern der Nenner-Regel: ohne sie würde ein 3×/Woche-Habit an vier von
    /// sieben Tagen als verpasst gelten und die Übersicht dauerhaft eintrüben.
    @Test("Ein nicht erledigter timesPerWeek-Habit bläht den Nenner nicht auf")
    func timesPerWeekNotCountedWhenSkipped() {
        let sport = habit("Sport", .daily)
        let laufen = habit("Laufen", .timesPerWeek(3))
        let result = overview(habits: [sport, laufen],
                              entries: [entry(sport, "2026-09-03")],
                              from: d("2026-09-03"), to: d("2026-09-03"), today: today)

        let day = result[d("2026-09-03")]!
        #expect(day.completed == 1)
        #expect(day.scheduled == 1, "Laufen war an diesem Tag nicht verpflichtend")
        #expect(day.isPerfect)
    }

    @Test("Ein erledigter timesPerWeek-Habit zählt in Zähler und Nenner")
    func timesPerWeekCountedWhenDone() {
        let sport = habit("Sport", .daily)
        let laufen = habit("Laufen", .timesPerWeek(3))
        let result = overview(habits: [sport, laufen],
                              entries: [entry(sport, "2026-09-03"), entry(laufen, "2026-09-03")],
                              from: d("2026-09-03"), to: d("2026-09-03"), today: today)

        let day = result[d("2026-09-03")]!
        #expect(day.completed == 2)
        #expect(day.scheduled == 2)
        // Der Anteil kann so nie über 100 % steigen.
        #expect(day.share == 1.0)
    }

    @Test("Ein pausierter Tag nimmt den Habit ganz heraus")
    func pausedRemovesHabit() {
        let sport = habit("Sport", .daily)
        let lesen = habit("Lesen", .daily)
        let result = overview(
            habits: [sport, lesen],
            entries: [entry(sport, "2026-09-03")],
            exceptions: [DayException(habitId: lesen.id, date: d("2026-09-03"), kind: .paused)],
            from: d("2026-09-03"), to: d("2026-09-03"), today: today)

        let day = result[d("2026-09-03")]!
        #expect(day.completed == 1)
        #expect(day.scheduled == 1)
        #expect(day.isPerfect)
    }

    @Test("Ein eingefrorener Tag bleibt im Nenner")
    func frozenStaysInDenominator() {
        let sport = habit("Sport", .daily)
        let lesen = habit("Lesen", .daily)
        let result = overview(
            habits: [sport, lesen],
            entries: [entry(sport, "2026-09-03")],
            exceptions: [DayException(habitId: lesen.id, date: d("2026-09-03"), kind: .frozen)],
            from: d("2026-09-03"), to: d("2026-09-03"), today: today)

        let day = result[d("2026-09-03")]!
        // Ein Freeze rettet den Streak, schönt die Übersicht aber nicht.
        #expect(day.completed == 1)
        #expect(day.scheduled == 2)
    }

    @Test("Eine globale Ausnahme gilt für alle Habits")
    func globalExceptionApplies() {
        let sport = habit("Sport", .daily)
        let lesen = habit("Lesen", .daily)
        let result = overview(
            habits: [sport, lesen], entries: [],
            exceptions: [DayException(habitId: nil, date: d("2026-09-03"), kind: .paused)],
            from: d("2026-09-03"), to: d("2026-09-03"), today: today)

        let day = result[d("2026-09-03")]!
        #expect(day.scheduled == 0)
        #expect(day.share == nil)
    }

    @Test("Ein Tag ohne Plan hat kein Ergebnis, nicht null Prozent")
    func dayWithoutPlan() {
        // 2026-08-29 ist ein Samstag.
        let arbeit = habit("Vokabeln", .weekdays([.monday, .tuesday, .wednesday, .thursday, .friday]))
        let result = overview(habits: [arbeit], entries: [],
                              from: d("2026-08-29"), to: d("2026-08-29"), today: today)

        let day = result[d("2026-08-29")]!
        #expect(day.scheduled == 0)
        #expect(day.share == nil, "Ein Tag ohne Plan ist nicht gescheitert")
        #expect(!day.isPerfect)
    }
}

@Suite("Kennzahlen der Übersicht")
struct OverviewStatsTests {

    @Test("Der laufende Tag bricht die Serie perfekter Tage nicht")
    func todayDoesNotBreakStreak() {
        let sport = habit("Sport", .daily, from: "2026-08-30")
        let entries = ["2026-08-31", "2026-09-01", "2026-09-02", "2026-09-03"]
            .map { entry(sport, $0) }

        let summaries = overview(habits: [sport], entries: entries,
                                 from: d("2026-08-30"), to: today, today: today)
        let stats = overviewStats(summaries: summaries,
                                  from: d("2026-08-30"), to: today, today: today)

        // Heute noch offen, aber nicht verloren; der 30.08. bricht die Serie.
        #expect(stats.perfectStreak == 4)
        #expect(stats.perfectDays == 4)
        #expect(stats.daysWithPlan == 6)
        #expect(stats.totalCompletions == 4)
    }

    @Test("Ein Tag ohne Plan unterbricht die Serie nicht")
    func emptyDayDoesNotBreakStreak() {
        // Mo–Fr: der 29. und 30.08. sind Wochenende und damit ohne Plan.
        let vokabeln = habit("Vokabeln",
                             .weekdays([.monday, .tuesday, .wednesday, .thursday, .friday]),
                             from: "2026-08-28")
        let entries = ["2026-08-28", "2026-08-31", "2026-09-01"].map { entry(vokabeln, $0) }
        let stichtag = d("2026-09-01")

        let summaries = overview(habits: [vokabeln], entries: entries,
                                 from: d("2026-08-28"), to: stichtag, today: stichtag)
        let stats = overviewStats(summaries: summaries,
                                  from: d("2026-08-28"), to: stichtag, today: stichtag)

        #expect(stats.perfectStreak == 3)
        #expect(stats.daysWithPlan == 3, "Samstag und Sonntag hatten keinen Plan")
    }

    @Test("Der arbeitsreichste Tag setzt den Maßstab der Farbskala")
    func busiestDay() {
        let a = habit("A", .daily), b = habit("B", .daily), c = habit("C", .daily)
        let entries = [entry(a, "2026-09-02"),
                       entry(a, "2026-09-03"), entry(b, "2026-09-03"), entry(c, "2026-09-03")]

        let summaries = overview(habits: [a, b, c], entries: entries,
                                 from: d("2026-09-02"), to: today, today: today)
        let stats = overviewStats(summaries: summaries,
                                  from: d("2026-09-02"), to: today, today: today)
        #expect(stats.busiestDay == 3)
        #expect(stats.totalCompletions == 4)
    }
}

@Suite("Ausschnitt der Übersicht")
struct OverviewSpanTests {

    @Test("Die Woche rastet von Montag bis Sonntag ein")
    func weekSnapsToCalendar() {
        // 2026-09-04 ist ein Freitag.
        let range = OverviewSpan.week.range(containing: d("2026-09-04"))
        #expect(range.from == d("2026-08-31"))
        #expect(range.to == d("2026-09-06"))
        #expect(range.from.weekday == .monday)
        #expect(range.to.weekday == .sunday)
    }

    @Test("Der Monat rastet vom Ersten bis zum Letzten ein")
    func monthSnapsToCalendar() {
        let range = OverviewSpan.month.range(containing: d("2026-02-17"))
        #expect(range.from == d("2026-02-01"))
        #expect(range.to == d("2026-02-28"))

        // 2028 ist ein Schaltjahr.
        #expect(OverviewSpan.month.range(containing: d("2028-02-17")).to == d("2028-02-29"))
    }

    @Test("Das Jahr umfasst 53 volle Wochen")
    func yearCoversFullWeeks() {
        let range = OverviewSpan.year.range(containing: d("2026-09-04"))
        #expect(range.from.weekday == .monday)
        #expect(range.to.weekday == .sunday)
        // 53 Wochen — genau die Spaltenzahl der Heatmap.
        #expect(range.from.days(until: range.to) + 1 == 53 * 7)
    }

    @Test("Blättern verschiebt um genau einen Ausschnitt")
    func shiftingMovesOneSpan() {
        #expect(OverviewSpan.week.shift(d("2026-09-04"), by: -1) == d("2026-08-28"))
        #expect(OverviewSpan.week.shift(d("2026-09-04"), by: 2) == d("2026-09-18"))
        #expect(OverviewSpan.month.shift(d("2026-09-04"), by: -1) == d("2026-08-04"))
        #expect(OverviewSpan.year.shift(d("2026-09-04"), by: -1) == d("2025-09-04"))
    }

    @Test("Beim Monatswechsel wird ein fehlender Tag gekürzt")
    func monthShiftClampsDay() {
        // Vom 31. Januar einen Monat weiter gibt es keinen 31. Februar.
        #expect(OverviewSpan.month.shift(d("2026-01-31"), by: 1) == d("2026-02-28"))
        #expect(OverviewSpan.month.shift(d("2026-03-31"), by: -1) == d("2026-02-28"))
        // Und über die Jahresgrenze hinweg.
        #expect(OverviewSpan.month.shift(d("2026-01-15"), by: -1) == d("2025-12-15"))
        #expect(OverviewSpan.month.shift(d("2026-12-15"), by: 1) == d("2027-01-15"))
    }

    @Test("Zurück und wieder vor landet am Ausgangspunkt")
    func shiftingIsReversible() {
        for span in OverviewSpan.allCases {
            let start = d("2026-09-04")
            #expect(span.shift(span.shift(start, by: -3), by: 3) == start)
        }
    }
}

@Suite("Farbstufen")
struct IntensityTests {

    private func summary(_ completed: Int, of scheduled: Int) -> DaySummary {
        DaySummary(date: today, completed: completed, scheduled: scheduled)
    }

    @Test("Ohne Erledigung bleibt die Stufe leer")
    func emptyDay() {
        #expect(intensityLevel(summary(0, of: 3), scale: .count, busiestDay: 5) == 0)
        #expect(intensityLevel(summary(0, of: 3), scale: .share, busiestDay: 5) == 0)
        // Auch ein Tag ohne Plan: nichts geplant ist nicht dasselbe wie versagt.
        #expect(intensityLevel(summary(0, of: 0), scale: .share, busiestDay: 5) == 0)
    }

    @Test("Nach Anzahl skaliert der arbeitsreichste Tag die Farbe")
    func countScale() {
        #expect(intensityLevel(summary(1, of: 8), scale: .count, busiestDay: 8) == 1)
        #expect(intensityLevel(summary(4, of: 8), scale: .count, busiestDay: 8) == 2)
        #expect(intensityLevel(summary(6, of: 8), scale: .count, busiestDay: 8) == 3)
        #expect(intensityLevel(summary(8, of: 8), scale: .count, busiestDay: 8) == 4)
    }

    @Test("Eine einzige Erledigung ist nie unsichtbar")
    func singleCompletionIsVisible() {
        // Bei 20 Habits wäre 1/20 rechnerisch Stufe 0,2 — der Tag würde wie ein
        // leerer aussehen. Erledigt ist erledigt: mindestens Stufe 1.
        #expect(intensityLevel(summary(1, of: 20), scale: .count, busiestDay: 20) == 1)
    }

    @Test("Nach Anteil zählt das Tagespensum, nicht die Menge")
    func shareScale() {
        // Ein Sonntag mit nur einem Habit ist voll erledigt und leuchtet auch so.
        #expect(intensityLevel(summary(1, of: 1), scale: .share, busiestDay: 8) == 4)
        #expect(intensityLevel(summary(2, of: 8), scale: .share, busiestDay: 8) == 1)
        #expect(intensityLevel(summary(4, of: 8), scale: .share, busiestDay: 8) == 2)
        #expect(intensityLevel(summary(8, of: 8), scale: .share, busiestDay: 8) == 4)
        // Derselbe Tag nach Anzahl bliebe blass — genau darin liegt der Unterschied.
        #expect(intensityLevel(summary(1, of: 1), scale: .count, busiestDay: 8) == 1)
    }

    @Test("Die Stufe bleibt immer zwischen 0 und 4")
    func levelStaysInRange() {
        #expect(intensityLevel(summary(9, of: 9), scale: .count, busiestDay: 2) == 4)
        #expect(intensityLevel(summary(3, of: 3), scale: .count, busiestDay: 0) == 0)
    }
}
