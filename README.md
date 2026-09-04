# Habit Tracker

Habit-Tracking für Mac, iPhone und Web — ein Datenmodell, eine API, drei Clients.

## Aufbau

```
spec/
  openapi.yaml      Vertrag für alle Clients
  fixtures/         Golden Tests: Swift und (später) TypeScript laufen dagegen
apple/
  HabitKit/         Swift Package (macOS 14+, iOS 17+)
    HabitCore       Domäne — keine Abhängigkeiten, kein UI, kein Foundation.Calendar
    HabitStore      lokale SQLite-Datenbank hinter dem HabitAPI-Protokoll
    HabitSync       SyncEngine gegen den Server
    HabitUI         geteilte SwiftUI-Views
server/             Fastify + Postgres — Sync-Hub
web/                React + Vite — einziger rein remote arbeitender Client
```

## Entwickeln

```bash
cd apple/HabitKit && swift test
```

Läuft ohne Xcode und deckt die gesamte Auswertungslogik ab — Regelauflösung,
Erfüllung, Streaks, Ausnahmen, Trend, Kalenderarithmetik.

## Drei Entscheidungen, die alles andere erklären

**Kalendertage statt Zeitstempel.** „Habe ich heute Sport gemacht?" ist eine
Kalenderfrage. `CalendarDate` rechnet über Howard Hinnants
Zivilkalender-Algorithmen statt über `Foundation.Calendar` — dadurch ist die
Domäne zeitzonenfrei, deterministisch und mechanisch nach TypeScript
übersetzbar.

**Natürliche Schlüssel statt IDs.** Ein Eintrag wird über `(habitId, date)`
adressiert. Jedes Schreiben ist damit ein idempotenter Upsert: ein nach einem
Verbindungsabbruch wiederholter Request ist harmlos, und zwei Geräte, die
denselben Tag abhaken, meinen dasselbe.

**Zeitplan und Ziel sind versioniert.** Eine Regel gilt ab `effectiveFrom`.
Vergangene Tage werden mit der damals gültigen Regel bewertet — sonst würde
eine Zielerhöhung von 2 L auf 3 L rückwirkend alle erfüllten Tage als verfehlt
erscheinen lassen.

## Warum Fixtures und nicht geteilter Code

Swift und TypeScript können sich keinen Code teilen. Statt zu hoffen, dass
beide Implementierungen gleich bleiben, laufen beide Test-Suites gegen
dieselben JSON-Dateien in `spec/fixtures/`. Weicht eine ab, schlagen Tests
fehl — statt dass die Zahlen leise auseinanderlaufen.

Jedes Fixture beschreibt einen Habit, seine Einträge, einen Stichtag und das
erwartete Ergebnis. Die Erwartungswerte sind von Hand hergeleitet, nicht aus
der Implementierung erzeugt.
