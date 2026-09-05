import Testing
import Foundation
@testable import HabitCore

private let today = CalendarDate(iso: "2026-09-30")!
private func d(_ iso: String) -> CalendarDate { CalendarDate(iso: iso)! }

private func habit(_ name: String = "Sport", from: String = "2026-08-01") -> Habit {
    Habit(name: name, rules: [HabitRule(effectiveFrom: d(from), schedule: .daily)])
}

/// Baut einen Verlauf: `muster` sagt je Tag ab dem 1. September, ob erledigt
/// wurde, `schlaf` die Stunden.
private func verlauf(_ h: Habit, _ muster: [Bool], _ schlaf: [Double])
-> (entries: [Entry], logs: [DayLog]) {
    var entries: [Entry] = []
    var logs: [DayLog] = []
    for (index, erledigt) in muster.enumerated() {
        let tag = d("2026-09-01").adding(days: index)
        if erledigt { entries.append(Entry(habitId: h.id, date: tag, value: 1)) }
        logs.append(DayLog(date: tag, sleepHours: schlaf[index]))
    }
    return (entries, logs)
}

@Suite("Korrelationen")
struct CorrelationTests {

    private func auswerten(_ h: Habit, _ muster: [Bool], _ schlaf: [Double]) -> [Correlation] {
        let (entries, logs) = verlauf(h, muster, schlaf)
        return correlations(habits: [h], entries: entries, dayLogs: logs,
                            from: d("2026-09-01"),
                            to: d("2026-09-01").adding(days: muster.count - 1),
                            today: today)
    }

    @Test("Ein deutlicher Zusammenhang wird gefunden")
    func findsStrongLink() {
        let sport = habit()
        // 10 Tage mit Sport und viel Schlaf, 8 ohne Sport und wenig.
        let muster = Array(repeating: true, count: 10) + Array(repeating: false, count: 8)
        let schlaf = Array(repeating: 8.0, count: 10) + Array(repeating: 6.0, count: 8)

        let ergebnis = auswerten(sport, muster, schlaf)
        let schlafBezug = try? #require(ergebnis.first { $0.metric == .sleepHours })
        #expect(schlafBezug?.strength == .strong)
        #expect(schlafBezug?.coefficient ?? 0 > 0.9)
        #expect(schlafBezug?.completedAverage == 8.0)
        #expect(schlafBezug?.missedAverage == 6.0)
        #expect(schlafBezug?.difference == 2.0)
        #expect(schlafBezug?.dayCount == 18)
    }

    /// Der wichtigste Test: bei wenigen Tagen findet man in Zufallsrauschen
    /// immer irgendetwas — und geglaubt wird es trotzdem.
    @Test("Unter der Mindestzahl an Tagen wird nichts behauptet")
    func silentBelowMinimum() {
        let sport = habit()
        // Perfekter Zusammenhang, aber nur zehn Tage.
        let muster = Array(repeating: true, count: 5) + Array(repeating: false, count: 5)
        let schlaf = Array(repeating: 9.0, count: 5) + Array(repeating: 5.0, count: 5)
        #expect(auswerten(sport, muster, schlaf).isEmpty)
        #expect(CorrelationRule.minimumDays == 14)
    }

    @Test("Eine zu kleine Gruppe genügt nicht, auch bei vielen Tagen")
    func silentWithLopsidedGroups() {
        let sport = habit()
        // 20 Tage, aber nur zwei ohne Sport: ein Mittelwert aus zwei Werten
        // ist keiner.
        let muster = Array(repeating: true, count: 18) + Array(repeating: false, count: 2)
        let schlaf = Array(repeating: 8.0, count: 18) + Array(repeating: 5.0, count: 2)
        #expect(auswerten(sport, muster, schlaf).isEmpty)
    }

    @Test("Ein schwacher Zusammenhang wird verschwiegen")
    func silentBelowThreshold() {
        let sport = habit()
        // Schlaf schwankt praktisch unabhängig vom Sport.
        let muster = (0..<20).map { $0 % 2 == 0 }
        let schlaf: [Double] = [7, 7.1, 7, 7.2, 7.1, 7, 7.2, 7.1, 7, 7.1,
                                7.1, 7, 7.2, 7, 7.1, 7.2, 7, 7.1, 7.2, 7]
        let ergebnis = auswerten(sport, muster, schlaf)
        #expect(ergebnis.first { $0.metric == .sleepHours } == nil)
    }

    @Test("Ohne Streuung im Journal gibt es nichts zu rechnen")
    func noVarianceNoResult() {
        let sport = habit()
        // Wer jeden Tag dasselbe einträgt, hat keine Erkenntnis, sondern eine
        // Gewohnheit beim Eintragen.
        let muster = (0..<20).map { $0 % 2 == 0 }
        let schlaf = Array(repeating: 7.0, count: 20)
        #expect(auswerten(sport, muster, schlaf).isEmpty)
        #expect(pearson(erledigt: [7, 7, 7], verpasst: [7, 7, 7]) == nil)
    }

    @Test("Ein negativer Zusammenhang wird ebenso gefunden")
    func findsNegativeLink() {
        let social = habit("Social Media")
        let muster = Array(repeating: true, count: 9) + Array(repeating: false, count: 9)
        let schlaf = Array(repeating: 5.5, count: 9) + Array(repeating: 7.5, count: 9)

        let ergebnis = auswerten(social, muster, schlaf)
        let bezug = try? #require(ergebnis.first { $0.metric == .sleepHours })
        #expect(bezug?.coefficient ?? 0 < -0.9)
        #expect(bezug?.difference == -2.0)
    }

    @Test("Tage ohne Journal-Eintrag zählen nicht mit")
    func skipsDaysWithoutLog() {
        let sport = habit()
        var entries: [Entry] = []
        var logs: [DayLog] = []
        for index in 0..<30 {
            let tag = d("2026-09-01").adding(days: index)
            if index % 2 == 0 { entries.append(Entry(habitId: sport.id, date: tag, value: 1)) }
            // Nur an den ersten zehn Tagen ein Journal.
            if index < 10 { logs.append(DayLog(date: tag, mood: index % 2 == 0 ? 5 : 2)) }
        }
        let ergebnis = correlations(habits: [sport], entries: entries, dayLogs: logs,
                                    from: d("2026-09-01"), to: d("2026-09-30"), today: today)
        // Zehn gemeinsame Tage reichen nicht, obwohl der Zusammenhang perfekt wäre.
        #expect(ergebnis.isEmpty)
    }

    @Test("Ausnahmen fallen heraus, weder erledigt noch verpasst")
    func exceptionsAreIgnored() {
        let sport = habit()
        let muster = Array(repeating: true, count: 10) + Array(repeating: false, count: 10)
        let schlaf = Array(repeating: 8.0, count: 10) + Array(repeating: 6.0, count: 10)
        let (entries, logs) = verlauf(sport, muster, schlaf)

        // Sechs der zehn verpassten Tage waren Urlaub — dann bleiben vier,
        // und das ist unter der Gruppengrenze.
        let urlaub = (10..<16).map {
            DayException(habitId: nil, date: d("2026-09-01").adding(days: $0), kind: .paused)
        }
        let ergebnis = correlations(habits: [sport], entries: entries, dayLogs: logs,
                                    exceptions: urlaub,
                                    from: d("2026-09-01"), to: d("2026-09-20"), today: today)
        #expect(ergebnis.isEmpty)
    }

    /// Der Fehler, den erst echte Daten gezeigt haben: mit einer festen
    /// Schwelle von 0,2 wurden reine Zufallszahlen als Befund gemeldet.
    @Test("Die Zufallshürde sinkt mit wachsender Datenmenge")
    func thresholdScalesWithSampleSize() {
        // Bei 30 Tagen braucht es rund 0,49, bei 100 nur noch 0,29.
        #expect(abs(CorrelationRule.requiredCoefficient(forDays: 30) - 0.493) < 0.01)
        #expect(abs(CorrelationRule.requiredCoefficient(forDays: 100) - 0.290) < 0.01)
        // Und nie unter die Sachgrenze, egal wie viele Tage.
        #expect(CorrelationRule.requiredCoefficient(forDays: 5000)
                == CorrelationRule.minimumCoefficient)
        // Mehr Daten dürfen die Hürde nie anheben.
        for tage in stride(from: 15, to: 300, by: 5) {
            #expect(CorrelationRule.requiredCoefficient(forDays: tage)
                    >= CorrelationRule.requiredCoefficient(forDays: tage + 5))
        }
    }

    @Test("Rauschen knapp über der alten Schwelle wird nicht mehr gemeldet")
    func rejectsNoiseThatUsedToPass() {
        let sport = habit()
        // Sechs von zehn erledigten Tagen mit acht Stunden, drei von zehn
        // verpassten — ergibt r = 0,30. Über der alten festen Grenze von 0,2,
        // aber bei zwanzig Tagen nicht von Zufall zu trennen (Hürde: 0,58).
        let muster = Array(repeating: true, count: 10) + Array(repeating: false, count: 10)
        let schlaf = Array(repeating: 8.0, count: 6) + Array(repeating: 6.0, count: 4)
                   + Array(repeating: 8.0, count: 3) + Array(repeating: 6.0, count: 7)

        let r = try! #require(pearson(erledigt: Array(schlaf[0..<10]),
                                      verpasst: Array(schlaf[10...])))
        #expect(r > CorrelationRule.minimumCoefficient, "läge über der alten Grenze")
        #expect(r < CorrelationRule.requiredCoefficient(forDays: 20))
        #expect(auswerten(sport, muster, schlaf).isEmpty, "und wird deshalb verschwiegen")
    }

    @Test("Die Schwellen der Stärke")
    func strengthThresholds() {
        #expect(CorrelationStrength(coefficient: 0.1) == nil)
        #expect(CorrelationStrength(coefficient: 0.3) == .weak)
        #expect(CorrelationStrength(coefficient: 0.5) == .moderate)
        #expect(CorrelationStrength(coefficient: 0.8) == .strong)
        // Das Vorzeichen ändert die Stärke nicht.
        #expect(CorrelationStrength(coefficient: -0.8) == .strong)
    }

    @Test("Der deutlichste Zusammenhang steht vorn")
    func sortedByStrength() {
        let sport = habit()
        var entries: [Entry] = []
        var logs: [DayLog] = []
        for index in 0..<20 {
            let tag = d("2026-09-01").adding(days: index)
            let erledigt = index < 10
            if erledigt { entries.append(Entry(habitId: sport.id, date: tag, value: 1)) }
            // Schlaf hängt deutlich zusammen, Stimmung nur mäßig.
            logs.append(DayLog(date: tag,
                               mood: erledigt ? (index % 3 == 0 ? 3 : 4) : 3,
                               sleepHours: erledigt ? 8.0 : 6.0))
        }
        let ergebnis = correlations(habits: [sport], entries: entries, dayLogs: logs,
                                    from: d("2026-09-01"), to: d("2026-09-20"), today: today)
        #expect(ergebnis.count >= 1)
        #expect(ergebnis.first?.metric == .sleepHours)
    }
}
