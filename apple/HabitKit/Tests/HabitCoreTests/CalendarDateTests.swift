import Testing
import Foundation
@testable import HabitCore

@Suite("CalendarDate")
struct CalendarDateTests {

    @Test("ISO-Runde: parsen und wieder ausgeben", arguments: [
        "2026-09-04", "2000-02-29", "1970-01-01", "1969-12-31", "2100-12-31",
    ])
    func isoRoundTrip(iso: String) throws {
        let date = try #require(CalendarDate(iso: iso))
        #expect(date.description == iso)
    }

    @Test("Ungültige Eingaben werden abgelehnt", arguments: [
        "2026-13-01",   // Monat 13
        "2026-02-30",   // gibt es nicht
        "2025-02-29",   // 2025 ist kein Schaltjahr
        "2026-9-4",     // nicht nullgepolstert
        "2026-09",      // unvollständig
        "heute",
    ])
    func rejectsInvalid(iso: String) {
        #expect(CalendarDate(iso: iso) == nil, "\(iso) hätte abgelehnt werden müssen")
    }

    @Test("Schaltjahre nach der vollen Regel")
    func leapYears() {
        #expect(CalendarDate.isLeapYear(2024))
        #expect(!CalendarDate.isLeapYear(2025))
        #expect(!CalendarDate.isLeapYear(1900))   // durch 100 teilbar
        #expect(CalendarDate.isLeapYear(2000))    // durch 400 teilbar
        #expect(CalendarDate(iso: "2024-02-29") != nil)
        #expect(CalendarDate(iso: "1900-02-29") == nil)
    }

    /// Erwartungswerte stammen aus einer unabhängigen Quelle (Pythons `datetime`),
    /// nicht aus dieser Implementierung.
    @Test("Wochentage", arguments: [
        ("2026-09-04", Weekday.friday),
        ("2026-08-31", Weekday.monday),
        ("2026-08-30", Weekday.sunday),
        ("2026-01-01", Weekday.thursday),
        ("1970-01-01", Weekday.thursday),
        ("2025-12-28", Weekday.sunday),
        ("2024-02-28", Weekday.wednesday),
    ])
    func weekdays(iso: String, expected: Weekday) throws {
        let date = try #require(CalendarDate(iso: iso))
        #expect(date.weekday == expected)
    }

    @Test("Wochenstart ist immer Montag")
    func weekStart() throws {
        // Fr 2026-09-04 liegt in der Woche ab Mo 2026-08-31.
        let friday = try #require(CalendarDate(iso: "2026-09-04"))
        #expect(friday.weekStart.description == "2026-08-31")
        #expect(friday.weekEnd.description == "2026-09-06")

        // Ein Sonntag gehört noch zur *vorherigen* Woche (ISO), nicht zur nächsten.
        let sunday = try #require(CalendarDate(iso: "2026-09-06"))
        #expect(sunday.weekStart.description == "2026-08-31")

        let monday = try #require(CalendarDate(iso: "2026-08-31"))
        #expect(monday.weekStart == monday)
    }

    @Test("Tagesarithmetik über Monats- und Jahresgrenzen")
    func arithmetic() throws {
        let silvester = try #require(CalendarDate(iso: "2025-12-31"))
        #expect(silvester.adding(days: 1).description == "2026-01-01")
        #expect(silvester.adding(days: -1).description == "2025-12-30")
        #expect(silvester.adding(days: 365).description == "2026-12-31")

        let feb = try #require(CalendarDate(iso: "2024-02-28"))
        #expect(feb.adding(days: 1).description == "2024-02-29")   // Schaltjahr
        #expect(feb.adding(days: 2).description == "2024-03-01")

        let a = try #require(CalendarDate(iso: "2026-08-30"))
        let b = try #require(CalendarDate(iso: "2026-09-04"))
        #expect(a.days(until: b) == 5)
        #expect(b.days(until: a) == -5)
        #expect(a.days(until: a) == 0)
    }

    @Test("Vor 1970 rechnet die Modulo-Korrektur richtig")
    func beforeEpoch() throws {
        let date = try #require(CalendarDate(iso: "1969-12-29"))
        #expect(date.dayNumber < 0)
        #expect(date.weekday == .monday)          // 1969-12-29 war ein Montag
        #expect(date.weekStart == date)
    }

    @Test("through liefert einen lückenlosen Bereich, rückwärts nichts")
    func through() throws {
        let from = try #require(CalendarDate(iso: "2026-08-30"))
        let to = try #require(CalendarDate(iso: "2026-09-04"))
        let range = from.through(to)
        #expect(range.count == 6)
        #expect(range.first == from)
        #expect(range.last == to)
        #expect(to.through(from).isEmpty)
        #expect(from.through(from) == [from])
    }

    @Test("Codable serialisiert als blanker String, nicht als Objekt")
    func codable() throws {
        let date = try #require(CalendarDate(iso: "2026-09-04"))
        let json = try JSONEncoder().encode(["d": date])
        #expect(String(decoding: json, as: UTF8.self) == #"{"d":"2026-09-04"}"#)
        let back = try JSONDecoder().decode([String: CalendarDate].self, from: json)
        #expect(back["d"] == date)
    }

    @Test("Monatsgrenzen")
    func monthBounds() throws {
        let mid = try #require(CalendarDate(iso: "2026-02-14"))
        #expect(mid.monthStart.description == "2026-02-01")
        #expect(mid.monthEnd.description == "2026-02-28")
        let leap = try #require(CalendarDate(iso: "2024-02-14"))
        #expect(leap.monthEnd.description == "2024-02-29")
    }
}
