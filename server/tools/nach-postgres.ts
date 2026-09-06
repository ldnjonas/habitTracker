/// Einmalig: den Bestand aus der SQLite-Datei nach Postgres heben.
///
/// **Warum das mehr ist als „Zeilen kopieren".** Jede Zeile trägt ihre
/// `server_seq`, und der Cursor jedes Clients ist genau diese Zahl. Wer den
/// Bestand ohne die Nummern überträgt, zwingt Mac und iPhone, alles neu zu
/// laden; wer dabei auch noch eine frische `server_info.instance` würfelt,
/// zwingt sie, ihren eigenen Stand vorher wegzuwerfen. Beides funktioniert und
/// beides ist unnötig: nimmt man Nummern **und** Kennung mit, merkt niemand
/// den Umzug.
///
/// Aufruf:
///     node --disable-warning=ExperimentalWarning tools/nach-postgres.ts \
///          habits.sqlite postgres://…
///
/// Ohne Ziel wird nach `./pgdaten` geschrieben — das eingebettete Postgres.

import { DatabaseSync } from "node:sqlite";
import { Db } from "../src/db.ts";
import { oeffneEingebettet } from "../src/pglite.ts";

/// Reihenfolge mit Bedacht: `habit_rule` und `habit_tag` hängen am Habit.
const TABELLEN = [
  "habit", "tag", "habit_rule", "habit_tag", "entry", "entry_event",
  "day_exception", "day_log", "focus_run", "freeze_ledger",
];

const quellePfad = process.argv[2] ?? "habits.sqlite";
const zielPfad = process.argv[3] ?? "./pgdaten";

const quelle = new DatabaseSync(quellePfad);
const ziel = zielPfad.startsWith("postgres")
  ? Db.oeffne(zielPfad)
  : await oeffneEingebettet(zielPfad);

console.log(`aus ${quellePfad} nach ${zielPfad}`);

// Die Kennung zuerst: sie entscheidet, ob die Clients den Umzug bemerken.
const kennung = quelle.prepare("SELECT instance FROM server_info WHERE id = 1").get() as
  { instance?: string } | undefined;
if (!kennung?.instance) throw new Error("Die Quelle hat keine server_info.instance");

await ziel.schreibe(
  `INSERT INTO server_info (id, instance) VALUES (1, ?)
   ON CONFLICT (id) DO UPDATE SET instance = excluded.instance`, kennung.instance);
console.log(`  Kennung übernommen: ${kennung.instance}`);

let gesamt = 0;
for (const tabelle of TABELLEN) {
  const spalten = (quelle.prepare(`PRAGMA table_info(${tabelle})`).all() as { name: string }[])
    .map((s) => s.name)
    // `dirty` ist eine Client-Markierung und steht im Serverschema nicht.
    .filter((n) => n !== "dirty");
  const zeilen = quelle.prepare(`SELECT * FROM "${tabelle}"`).all() as Record<string, unknown>[];

  const namen = spalten.map((s) => `"${s}"`).join(", ");
  const platz = spalten.map(() => "?").join(", ");
  await ziel.inTransaktion(async () => {
    for (const zeile of zeilen) {
      await ziel.schreibe(
        `INSERT INTO "${tabelle}" (${namen}) VALUES (${platz}) ON CONFLICT DO NOTHING`,
        ...spalten.map((s) => zeile[s] ?? null));
    }
  });
  console.log(`  ${tabelle}: ${zeilen.length}`);
  gesamt += zeilen.length;
}

// Die Folge auf den höchsten vergebenen Wert setzen. Eine Nummer darunter, und
// der nächste Schreibvorgang vergäbe eine, die schon existiert.
const hoechste = Number(
  (quelle.prepare("SELECT value FROM sync_sequence WHERE id = 1").get() as { value: number }).value);
await ziel.schreibe(`UPDATE sync_sequence SET value = ? WHERE id = 1`, hoechste);

console.log(`  Folge steht auf ${hoechste}`);
console.log(`fertig: ${gesamt} Zeilen`);

quelle.close();
await ziel.schliesse();
