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

Tests der gesamten Auswertungslogik — Regelauflösung, Erfüllung, Streaks,
Ausnahmen, Trend, Kalenderarithmetik, Datenbank-Invarianten:

```bash
cd apple/HabitKit && swift test
```

Mac-App bauen und starten:

```bash
cd apple && xcodegen generate && open HabitTracker.xcodeproj
```

Das `.xcodeproj` wird aus `apple/project.yml` erzeugt und ist gitignored —
eine generierte Datei, die niemand lesen oder zusammenführen will. XcodeGen
kommt über `brew install xcodegen`. Nach jeder Änderung an `project.yml` oder
nach dem Hinzufügen neuer Dateien `xcodegen generate` erneut ausführen.

Die Datenbank liegt unter
`~/Library/Application Support/HabitTracker/habits.sqlite`.

Das App-Icon wird erzeugt, nicht gemalt — `python3 tools/make-app-icon.py`
schreibt alle zehn Größen in den Asset-Katalog. Zeigt das Dock danach noch das
alte, hält LaunchServices es fest: `touch <App>.app && killall Dock`.

## Zeiterfassung

Ein Habit mit „Sitzungen mit Uhrzeit erfassen“ nimmt Start und Ende statt einer
Zahl. Der Tageswert ergibt sich aus der Summe der Sitzungsdauern, die
Wochensumme aus den Tageswerten — beides hält der Store, nicht der Aufrufer.

Zwei Regeln, die daraus folgen: Liegt ein Ende vor, **gilt die Dauer und nicht
der mitgeschickte Wert** — zwei Felder, die dasselbe über dieselbe Sitzung
sagen, driften sonst auseinander. Und eine Sitzung über Mitternacht zählt zum
Starttag, weil `date` denormalisiert ist und die Zuordnung nicht von der
Zeitzone des Lesers abhängen darf.

Der Schnitt in der Zeit-Karte bezieht sich auf Tage **mit** Aktivität. Ein
Schnitt über alle Tage beantwortet nichts: er sinkt, sobald man den Zeitraum
vergrößert, ohne dass sich am Verhalten etwas geändert hat.

## Fokus

Ein Fokus ist ein selbst gesetztes Fenster — typischerweise sieben Tage — in dem
lückenlos alles erfüllt werden soll. Der Streak fragt „wie lange schon?", der
Fokus fragt „schaffe ich *diese* Woche?". Das ist ein anderes Versprechen: es
hat einen Anfang, ein Ende und ein Ergebnis, und man kann es verlieren, ohne
alles zu verlieren.

**Gespeichert wird nur die Absicht, nie das Ergebnis.** Ob ein Lauf durchgezogen
wurde, ergibt sich aus den Einträgen — ein gespeichertes „geschafft" würde von
ihnen abdriften, sobald ein Tag nachträglich korrigiert wird.

Bewertet wird nach derselben Regel wie die Übersicht: ein Tag ist geschafft,
wenn alles erledigt ist, was an ihm *verpflichtend* war. Daraus folgt ohne
Sonderfälle, dass ein Wochenziel keinen einzelnen Tag reißen kann und Urlaub
den Tag herausnimmt. Ein Streak Freeze rettet einen Fokus dagegen nicht — er ist
das strengere Versprechen.

## Streak Freezes

Ein durchgezogener Fokus-Lauf bringt einen Freeze, höchstens drei auf dem Konto.
Eingelöst rettet er einen **bereits verpassten** Tag: der Streak hält, die Quote
bleibt ehrlich — ein eingefrorener Tag steht weiter in ihrem Nenner.

Drei Regeln, die zusammen verhindern, dass der Streak wertlos wird:

- **Ein Ledger, kein Zähler.** Der Kontostand ist die Summe der Buchungen. Ein
  Zähler kann falsch werden, ohne dass man sieht wie; beim Sync bleibt eine
  Buchungsreihe konfliktfrei, weil nur angehängt wird.
- **Die Obergrenze deckelt, und darüber verfällt der Anspruch.** Sonst sammelt
  sich über Monate ein Polster an, das jeden Streak beliebig am Leben hält.
- **Ein Freeze überbrückt, er verlängert nicht.** Er rechnet sich keinen
  erledigten Tag an — sonst ließe sich Streak kaufen. Und er geht nur auf
  Vergangenes: ein Freeze auf die Zukunft wäre eine Vorabentschuldigung.

## Sicherung

„Sicherung → Sichern" schreibt eine JSON-Datei — den gesamten Bestand oder
einzelne Habits samt Verlauf. Das Format steht als `BackupFile` in
`spec/openapi.yaml`; der spätere Node-Server liest und schreibt dieselben
Dateien über `GET /backup` und `POST /backup/import`.

Beim Einspielen aktualisiert **Zusammenführen** eine vorhandene Zeile nur, wenn
die Datei ein neueres `updatedAt` trägt — dieselbe Last-Write-Wins-Regel wie
beim Sync. **Ersetzen** verwirft den bisherigen Bestand vollständig. Einträge
werden dabei über `(habitId, date)` erkannt, nicht über ihre `id`: zwei Geräte,
die denselben Tag abgehakt haben, meinen dieselbe Sache.

Enthalten sind nur lebende Zeilen. Grabsteine gehören zum Sync-Protokoll, nicht
zur Sicherung — die beschreibt den Bestand, nicht seine Geschichte.

## Vier Entscheidungen, die alles andere erklären

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

**Darstellungsregeln, die beide Clients treffen müssen, stehen in der Domäne.**
Die Farbstufe eines Tages in der Übersichts-Heatmap (`intensityLevel`) ist keine
Sache der Oberfläche: läge sie in der View, zeigten Mac und Browser für denselben
Bestand verschiedene Bilder. In `HabitCore` steht *welche* Stufe, in der View nur,
*wie* sie aussieht.

## Warum Fixtures und nicht geteilter Code

Swift und TypeScript können sich keinen Code teilen. Statt zu hoffen, dass
beide Implementierungen gleich bleiben, laufen beide Test-Suites gegen
dieselben JSON-Dateien in `spec/fixtures/`. Weicht eine ab, schlagen Tests
fehl — statt dass die Zahlen leise auseinanderlaufen.

Jedes Fixture beschreibt einen Habit, seine Einträge, einen Stichtag und das
erwartete Ergebnis. Die Erwartungswerte sind von Hand hergeleitet, nicht aus
der Implementierung erzeugt.
