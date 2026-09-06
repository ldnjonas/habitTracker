# Abgleich-Server

Der Knotenpunkt zwischen Mac, iPhone und (später) WebApp. Er hält keine Logik —
Streaks, Quoten und Zusammenhänge rechnet jeder Client selbst aus `HabitCore`
bzw. dessen TypeScript-Fassung. Der Server verwahrt Zeilen und sagt, was sich
seit wann geändert hat.

## Starten

```bash
cd server
npm install
export HABIT_TOKEN="$(openssl rand -base64 32)"
npm start
```

Ohne `HABIT_TOKEN` **startet er nicht**. Das ist Absicht: ein Abgleich-Server
ohne Schutz im Netz gibt den kompletten Verlauf preis, und einer, der „läuft",
fällt niemandem als Problem auf.

| Umgebungsvariable | Vorgabe | Bedeutung |
|---|---|---|
| `HABIT_TOKEN` | — | Pflicht, mindestens 16 Zeichen |
| `HABIT_DB` | `habits.sqlite` | Pfad der Datenbankdatei |
| `PORT` | `8080` | |
| `LOG_LEVEL` | `info` | |
| `HABIT_BACKFILL_DAYS` | `7` | Wie weit zurück geschrieben werden darf; `0` = unbegrenzt |
| `TZ` | Systemzone | Welcher Tag „heute" ist |

`TZ` ist keine Kosmetik: der Server entscheidet über „heute", und ein Habit,
der um 23:30 abgehakt wird, soll zu diesem Tag gehören und nicht zum nächsten.
Steht der Server in UTC und das Telefon in Zürich, springt der Tageswechsel
zwei Stunden zu früh.

```bash
npm test     # Typprüfung, dann 121 Tests — ohne Netz und ohne Datei
```

`npm test` prüft zuerst die Typen und führt dann die Tests aus. Der
Typprüfer ist die einzige Entwicklungs-Abhängigkeit: Node entfernt Typen beim
Ausführen, ohne sie anzusehen — ungeprüft wäre jede Typangabe ein Kommentar,
den nie jemand liest. Ausgeliefert wird trotzdem nichts Gebautes.

## Warum SQLite und nicht Postgres

Der ursprüngliche Plan sah Postgres vor. Dagegen sprechen drei Dinge:

1. **Das Client-Schema ist SQLite.** Damit sind Server- und Client-Schema
   textlich vergleichbar statt bloß ähnlich — genau das Ziel, aus dem im Client
   explizites SQL statt SwiftData steht.
2. **Ein Nutzer, zwei bis drei Geräte.** Was Postgres besser kann, kommt hier
   nicht vor.
3. **Hosting.** Eine Datei auf einem kleinen Server statt einer verwalteten
   Datenbank. Sicherung heißt: Datei kopieren.

Der Weg zurück bleibt offen — das SQL ist gewöhnlich, und `src/db.ts` ist die
einzige Datei, die `node:sqlite` kennt.

**Keine nativen Abhängigkeiten, kein Build-Schritt.** SQLite und TypeScript
bringt Node selbst mit, einzige Abhängigkeit ist Fastify. Der Server läuft
überall, wo Node ≥ 24 läuft, ohne Compiler-Werkzeug.

## Wie der Abgleich funktioniert

**Eine einzige Folge über alle Tabellen.** `sync_sequence` zählt hoch, jede
geschriebene Zeile bekommt die nächste Nummer. Der Cursor eines Clients ist
genau diese Zahl — er muss sich nichts je Tabelle merken, und die Reihenfolge
bleibt tabellenübergreifend eindeutig.

```
GET  /sync?since=<seq>&limit=500   → alle Zeilen mit server_seq > since
POST /sync                          → lokale Änderungen hochladen
GET  /health                        → ohne Token
```

## Die Ressourcen in `src/routes/`

Der Abgleich überträgt Zeilen; die Endpunkte beantworten Fragen. Beide
schreiben in dieselben Tabellen, und **jede Schreibung vergibt eine
Sequenznummer** — eine Zeile, die im Browser entsteht und keine bekommt, steht
in der Datenbank und taucht trotzdem in keinem Delta auf. Der Mac sähe sie nie.
Ein eigener Test geht deshalb jeden schreibenden Endpunkt durch und prüft genau
das.

Die Regeln stehen in `src/store.ts`, nicht in den Endpunkten: sonst könnte die
WebApp Zustände erzeugen, die die Mac-App nie erzeugt.

- `entry.value == Σ events` — beim Setzen und Löschen einer Sitzung neu gerechnet
- Kaskadierte Grabsteine samt `deleted_with`; **alle mit einer Sequenznummer**,
  damit ein Client die Löschung nie halb sieht
- Nur ein offener Fokus-Lauf; ein gerissener blockiert nicht
- Ein Freeze nur auf einen vergangenen, verpassten Tag — und Ausnahme und
  Abbuchung in einem Zug
- Die Nachtrage-Grenze, in beide Richtungen: rückwirkend begrenzt, im Voraus gar nicht

**Einen Unterschied zum Client gibt es bewusst:** `POST /backup/import` mit
`replace` löscht nicht hart, sondern setzt Grabsteine. Im Client ist eine harte
Löschung richtig — dort ist niemandem mehr etwas mitzuteilen. Hier schon: ein
Gerät mit altem Cursor erführe von einer harten Löschung nie und schöbe die
Zeilen beim nächsten Hochladen zurück.

**Grabsteine werden mitgeliefert.** Ohne sie käme eine Löschung nie beim anderen
Gerät an; dort stünde der Eintrag weiter, und niemand wüsste, warum.

**Der Server setzt `updatedAt` und vergibt `server_seq`.** Bei Last-Write-Wins
entscheidet genau dieser Zeitstempel — und die Uhr eines Clients ist nicht
vertrauenswürdig. Liegt sie mehr als fünf Minuten in der Zukunft, wird sie auf
die Serverzeit gestutzt. Sonst gewänne ein falsch gestelltes Gerät dauerhaft
jeden Konflikt, ohne dass jemand darauf käme, warum.

**Die Nutzlast hat dieselbe Form wie die Sicherungsdatei.** Ein Habit kommt samt
Regeln und Tags, nicht als drei getrennte Tabellen — der Client hat die passenden
Codable-Typen damit schon, und die Zerlegung bleibt Sache des Servers. Daraus
folgt: **jede Änderung an Regeln oder Tags muss das `updatedAt` des Habits
anheben**, sonst bleibt sie beim Abgleich unsichtbar.

**Das Freeze-Konto wird nur angehängt.** Eine vorhandene Buchung bleibt, wie sie
ist; eine Korrektur ist eine Gegenbuchung. Deshalb hat es weder `updatedAt` noch
Grabstein und nimmt am Last-Write-Wins nicht teil.

**Ein Delta wird ganz oder gar nicht angewandt.** Ein halb angewandtes wäre
schlimmer als ein abgelehntes: der Client hielte seinen Cursor für weiter, als
er ist, und die fehlenden Zeilen kämen nie wieder.

## Die Domäne in `src/domain/`

Eine Portierung von `apple/HabitKit/Sources/HabitCore/`, Datei für Datei mit
denselben Namen — ein Vergleich der beiden soll ein Diff bleiben und keine
Suchaufgabe. Sie rechnet Streaks, Quoten, Übersicht, Fokus, Summen und
Zusammenhänge; der Abgleich in `sync.ts` benutzt nichts davon.

**Der Preis ist doppelte Logik**, und dagegen hilft nur der geteilte Vertrag:
`spec/fixtures/` beschreibt Fälle samt Erwartung, und **beide Seiten rechnen
dieselben Dateien nach**. Weicht eine Zahl ab, schlägt eine Seite fehl — statt
dass Mac und Browser stillschweigend Verschiedenes anzeigen.

Drei Abweichungen von Swift sind bewusst und stehen in den jeweiligen Dateien:
ein Kalendertag ist die ISO-Zeichenkette selbst, jede ganzzahlige Division ist
`Math.trunc`, und Swifts `enum` mit assoziierten Werten wird zur unterschiedenen
Vereinigung über `code`.

## Was noch fehlt

- **Die WebApp selbst** (`web/`). Der Server soll sie später über
  `@fastify/static` mit ausliefern: ein Ursprung, eine Adresse, kein CORS.
- **Der Login-Flow** (`/auth/register`, `/auth/login`, `/auth/refresh` in der
  Spec). Ungebaut, weil v1 mit einem festen Token auskommt.
- **Mehrbenutzerbetrieb.** `user_id` steht in jeder Tabelle, aber v1 prüft nur
  ein statisches Token und trennt nichts. Der Login-Flow steht in der Spec.
