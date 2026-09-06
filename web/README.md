# Die WebApp

Dasselbe Konto auf dem Telefon, ohne Entwicklerkonto. Ein reiner Client: sie
rechnet nichts selbst, sondern fragt den Server — und der rechnet mit derselben
Domäne, die auch die Mac-App benutzt.

## Starten

```bash
cd web && npm install && npm run dev
```

Vite läuft auf 5173 und leitet die API an `localhost:8080` weiter. Der Server
muss also nebenher laufen; ohne ihn zeigt die Anmeldung „Der Server ist nicht
erreichbar".

Für den echten Betrieb wird gebaut, und der Server liefert das Ergebnis aus:

```bash
cd web && npm run build     # → web/dist
cd ../server && npm start   # liefert web/dist mit aus
```

Ein Ursprung, eine Adresse, kein CORS, eine Sache zum Starten. Fehlt
`web/dist`, sagt der Server das beim Start und bleibt ein reiner API-Server.

## Die Typen kommen aus dem Server

`src/api/types.ts` gibt die Typen aus `server/src/domain/` weiter, statt sie mit
`openapi-typescript` aus `spec/openapi.yaml` zu erzeugen.

Der Grund für den Umweg über die Spec war, dass eine Abweichung zwischen Server
und Oberfläche ein Übersetzungsfehler sein soll und kein Rätsel zur Laufzeit.
Genau das erreicht der direkte Weg besser: die Domäne des Servers **ist**
TypeScript, also gibt es keine zweite Beschreibung, die von ihr abweichen
könnte. Eine erzeugte Fassung beschreibt nur, was der Server tun *sollte*.

Alles davon ist `import type` — im gebauten Bündel landet keine Zeile.

## Was hier bewusst nicht steht

**Kein Router.** Vier Register, ein Zustand. Ein Router brächte Adressen für
Unterseiten mit, die es nicht gibt.

**Keine Zustandsbibliothek.** Jede Ansicht lädt, was sie braucht, und lädt nach
einer Änderung neu. Bei einem Aufruf je Ansicht ist ein Zwischenspeicher mehr
Verwaltung als Nutzen — und die Heute-Ansicht hat sowieso nur einen.

**Keine Diagrammbibliothek.** Die Heatmap wird ein Inline-SVG: 371 Rechtecke
sind kein Grund für 200 kB.

**Keine Icon-Bibliothek.** Die Mac-App speichert SF-Symbolnamen; `ui/symbole.ts`
übersetzt die 23 aus dem Editor in Emoji. Was nicht darin steht, bekommt den
ersten Buchstaben seines Namens.

## Bedienung

Mobil zuerst. Registerleiste unten, weil oben der Daumen nicht hinkommt;
Fingerziele mindestens 44 px; nichts, was auf Zeigen mit dem Mauszeiger beruht.
Der Bereich unter der Home-Anzeige bleibt frei (`env(safe-area-inset-bottom)`).

**Das Token liegt im `localStorage`.** Wer den Browser hat, hat den Zugang. Auf
einem privaten Telefon ist das vertretbar, aber es ist eine Entscheidung —
deshalb steht sie auch auf der Anmeldeseite und nicht nur hier.

## Symbole

```bash
python3 tools/make-app-icon.py --web
```

Dieselbe Heatmap wie das Mac-Icon, andere Formen: randlos statt im Squircle
(iOS und Android runden selbst — ein eingebauter Rahmen sähe aus wie ein Bild
in einem Rahmen in einem Rahmen) und einmal mit 10 % Schutzzone für
`maskable`, weil Android je nach Gerät beschneidet.

## Stand

Gebaut ist das Gerüst und die Heute-Ansicht. Übersicht, Fokus und der Rest
sagen vorerst, dass sie noch nicht gebaut sind — ein Register, das ohne
Erklärung nichts tut, ist schlimmer als eines, das fehlt.
