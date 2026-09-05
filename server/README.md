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

```bash
npm test     # Typprüfung, dann 90 Tests — ohne Netz und ohne Datei
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

- **Die REST-Ressourcen** aus `spec/openapi.yaml` (`/habits`, `/entries`, …).
  Die Domänenlogik dafür steht jetzt bereit; was fehlt, sind die Endpunkte und
  die Invarianten des Servers.
- **Mehrbenutzerbetrieb.** `user_id` steht in jeder Tabelle, aber v1 prüft nur
  ein statisches Token und trennt nichts. Der Login-Flow steht in der Spec.
