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

## Die Domäne kommt aus dem Server — auch als Code

`src/api/types.ts` gibt die Typen aus `server/src/domain/` weiter, statt sie mit
`openapi-typescript` aus `spec/openapi.yaml` zu erzeugen.

Der Grund für den Umweg über die Spec war, dass eine Abweichung zwischen Server
und Oberfläche ein Übersetzungsfehler sein soll und kein Rätsel zur Laufzeit.
Genau das erreicht der direkte Weg besser: die Domäne des Servers **ist**
TypeScript, also gibt es keine zweite Beschreibung, die von ihr abweichen
könnte. Eine erzeugte Fassung beschreibt nur, was der Server tun *sollte*.

Dasselbe gilt für die paar **Funktionen**, die die Oberfläche wirklich selbst
braucht: `weekday`, `addDays`, `through`, `spanRange`, `spanShift`,
`intensityLevel`. Sie sind rein, hängen an nichts und werden beim Bauen
herausgeschüttelt, wenn sie niemand aufruft. Sie hier nachzubauen hieße,
Hinnants Zivilkalender ein drittes Mal zu schreiben — und die dritte Fassung
wäre irgendwann die falsche.

Was **nicht** hierher wandert, ist die Auswertung: Streaks, Quoten und
Zusammenhänge rechnet der Server. Sonst gäbe es zwei Antworten auf dieselbe
Frage.

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

## Was wo steht

| Register | Was es kann |
|---|---|
| **Heute** | Abhaken, Menge zählen, Verstoß melden — mit Streak und Trend je Zeile |
| **Übersicht** | Heatmap über alle Habits: Woche · Monat · Jahr, blättern, Tagesdetail, Maßstab nach Anzahl oder Anteil |
| **Fokus** | Läufe starten und beenden, Verlauf mit Ergebnis, Freeze-Konto |
| **Mehr** | Alle Habits (anlegen, ändern, sortieren, archivieren, löschen) · Journal samt Zusammenhängen · Tags · Papierkorb · Sicherung · Abmelden |

Ein Habit-Detail gibt es aus der Liste heraus: Jahresbild in seiner Farbe,
Wochentagsverteilung, Streak-Kacheln, Summen und Sitzungen. Ein Tag darin
lässt sich zum Urlaub oder Ruhetag erklären, und ein verpasster einfrieren.

**Was hier bewusst fehlt:** Sitzungen von Hand anzulegen. Sie entstehen auf dem
Mac beim Starten und Stoppen; im Browser werden sie gezeigt, aber nicht
erfasst — ein Knopf dafür wäre auf dem Telefon eine Stoppuhr, und die will
anders gebaut sein als ein Formular.

## Wann welche Ansicht neu lädt

Jede lädt beim Öffnen, und nach einer Änderung noch einmal. Wer im Editor etwas
sichert, stößt zusätzlich alle anderen an — sonst zeigte die Heute-Ansicht noch
den alten Namen.
