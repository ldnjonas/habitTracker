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
    HabitUI         geteilte SwiftUI-Views — Bausteine und AppState, plattformneutral
  HabitTrackerMac/  Mac-App: Anordnung, Menüleiste, Tastenkürzel
  HabitTrackerIOS/  iPhone-App: Anordnung, Registerleiste, Wischgesten
server/             Fastify + SQLite — Sync-Hub (siehe server/README.md)
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

Das App-Icon wird erzeugt, nicht gemalt. `python3 tools/make-app-icon.py`
schreibt alle zehn macOS-Größen in den Asset-Katalog, `--ios` das eine 1024er
fürs iPhone, `--web` die Symbole der WebApp. Zeigt das Dock danach noch das
alte, hält LaunchServices es fest: `touch <App>.app && killall Dock`.

### Die iPhone-App

```bash
cd apple && xcodegen generate
xcodebuild -scheme HabitTrackerIOS -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

**Xcode liefert für iOS nur die Kopfdateien mit.** Fehlt die
Plattform-Unterstützung, findet `xcodebuild` nicht einmal ein Ziel:

```bash
xcodebuild -downloadPlatform iOS     # rund 8 GB, einmalig
```

**Aufs eigene Gerät, ohne Entwicklerkonto.** Xcode signiert mit deiner Apple-ID
(„Personal Team"); das Profil gilt **7 Tage**, danach startet die App nicht
mehr und ein Neubau setzt die Uhr zurück. Höchstens 3 Apps gleichzeitig, kein
Widget (das bräuchte App Groups), keine Push-Nachrichten, kein TestFlight.

Die Team-ID gehört in `apple/Signing.xcconfig` — die Datei ist gitignored, eine
persönliche Apple-ID gehört niemandem sonst:

```
DEVELOPMENT_TEAM = XXXXXXXXXX
```

Erste Installation per Kabel; danach in Xcode unter *Window → Devices and
Simulators* „Connect via network" anhaken, dann genügt dasselbe WLAN.

**Die Daten überleben das.** Ein Neubau über dieselbe App ist ein Update, der
Container bleibt — und selbst nach Löschen und Neuinstallieren holt der erste
Abgleich alles vom Server zurück.

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

## Abgleich

`server/` ist der Knotenpunkt zwischen Mac, iPhone und später der WebApp. Er
hält keine Logik — Streaks und Auswertungen rechnet jeder Client selbst; der
Server verwahrt Zeilen und sagt, was sich seit wann geändert hat.

Eine einzige Folge über alle Tabellen: der Cursor eines Clients ist genau diese
Zahl. Grabsteine wandern mit, sonst käme eine Löschung nie beim anderen Gerät
an. Und der Server setzt die Zeitstempel selbst — bei Last-Write-Wins
entscheidet genau der, und die Uhr eines Clients ist nicht vertrauenswürdig.

Entgegen dem ursprünglichen Plan **SQLite statt Postgres**: das Client-Schema
ist SQLite, damit werden beide textlich vergleichbar statt bloß ähnlich; ein
Nutzer mit drei Geräten braucht nichts von dem, was Postgres besser kann; und
das Hosting ist eine Datei statt einer verwalteten Datenbank. Details und der
Weg zurück stehen in `server/README.md`.

## Bedienung

Rechtsklick auf einen Habit — in der Seitenleiste, in „Heute" oder in „Alle
Habits" — öffnet Bearbeiten, Archivieren und Löschen; dieselben Aktionen liegen
auf dem „…"-Knopf jeder Zeile und in der Toolbar der Detailansicht.

In „Heute" haken die Ziffern **1 bis 9** die Habits der Reihe nach ab; die Ziffer
steht in der Zeile, sonst wüsste niemand davon. In „Alle Habits" lässt sich die
Reihenfolge ziehen — nur ohne aktiven Filter, weil eine Verschiebung in einer
gefilterten Liste sich nicht auf die Gesamtreihenfolge übertragen ließe.

Das Menüleisten-Symbol zeigt den Tagesstand und hakt ab, ohne das Fenster zu
öffnen.

## Journal und Zusammenhänge

Stimmung, Energie und Schlaf lassen sich je Tag erfassen — alles freiwillig, denn
ein Journal, das vollständig sein muss, führt niemand. Nicht Erfasstes fällt aus
der Auswertung heraus, statt als Null zu zählen.

Daraus sucht die Übersicht Zusammenhänge und formuliert sie als Satz: „An Tagen
mit Lesen schläfst du im Schnitt 1 h 27 min länger.“

**Die Zurückhaltung ist der schwierige Teil.** Bei wenigen Tagen findet man in
Zufallsrauschen immer irgendetwas, und angezeigt wird es geglaubt. Die Hürde für
`r` richtet sich deshalb nach der Datenmenge — 0,58 bei 20 Tagen, 0,29 bei 100 —
und nicht nach einer festen Zahl. Das ist streng gewählt, weil über acht Habits
und drei Größen zwei Dutzend Paare gleichzeitig geprüft werden.

Der Nutzen zeigte sich sofort: mit einer festen Schwelle von 0,2 meldete die
Auswertung an Zufallsdaten sechs „Befunde“, darunter einen für eine Größe, die
als Zufallszahl erzeugt worden war. Mit der datenabhängigen Hürde: keinen.

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

### Täglich, ohne Zutun

Eine Sicherung, an die man denken muss, fehlt genau dann, wenn man sie braucht.
Die Mac-App legt deshalb selbst eine an — beim Start und beim Tageswechsel, nach
`~/Library/Application Support/HabitTracker/Sicherungen/`.

Zwei Regeln halten den Ordner brauchbar:

- **Hat sich nichts geändert, wird nichts geschrieben.** Eine Reihe gleicher
  Dateien sagt nichts, was nicht schon im Datum steht — und verdrängt beim
  Aufräumen die Stände, die sich unterscheiden.
- **Die letzten 14 Tage bleiben vollständig, davor je Monat eine, bis zwölf
  Monate zurück.** Ein gleitendes Fenster allein wäre zu kurz: einen Fehler von
  vorletzter Woche bemerkt man, einen von vor einem halben Jahr manchmal erst,
  wenn die Zahlen nicht mehr stimmen. Alles aufzuheben wäre das andere Extrem.

**Wogegen das hilft und wogegen nicht:** gegen Fehlgriffe — einen versehentlich
gelöschten Habit, einen Abgleich, der etwas überschreibt, eine Datenbank, die
nicht mehr aufgeht. Nicht gegen den Verlust der Festplatte, denn die Dateien
liegen daneben. Deshalb ist der Ordner aus der App heraus erreichbar: wer mehr
will, richtet Time Machine darauf oder kopiert ihn weg.

Abschalten geht auf derselben Seite. Etwas, das ungefragt Dateien anlegt, muss
sich abstellen lassen.

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

Die Erwartungswerte sind von Hand hergeleitet, nicht aus der Implementierung
erzeugt — sonst prüften sie nur, dass sich nichts geändert hat, und nicht, dass
etwas stimmt.

Nach Art getrennt, weil die Formen verschieden sind:

| Ordner | Was ein Fixture beschreibt |
|---|---|
| `stats/` | ein Habit, seine Einträge, ein Stichtag — Streak, Quote, Wochentage, Trend |
| `overview/` | mehrere Habits je Tag — an einem einzelnen lässt sich die Nenner-Regel gar nicht zeigen |
| `focus/` | einen Lauf samt Einträgen, oder fertige Ergebnisse für die Bilanz |
| `totals/` | Sitzungen und Tageswerte, Summen nach Tag und Woche |
| `correlations/` | ein Journal — und meistens die Erwartung, dass **nichts** berichtet wird |
| `freeze/` | Läufe und Buchungen: Kontostand, Anspruch, Obergrenze |
| `backup/` | eine echte Sicherungsdatei; beide Fassungen müssen sie **Byte für Byte** wieder herausgeben |
