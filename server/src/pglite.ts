import { PGlite } from "@electric-sql/pglite";
import { readFileSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { Db, type Treiber, type Zeile } from "./db.ts";

/// Postgres im eigenen Prozess — für Tests und für den Betrieb ohne Server.
///
/// PGlite ist kein Nachbau, sondern dasselbe Postgres nach WebAssembly
/// übersetzt. Deshalb prüfen die Tests denselben Dialekt, dieselben Typen und
/// dieselben Fehlermeldungen wie Supabase, ohne dass ein Container laufen muss.
///
/// **Diese Datei wird von der Edge Function nie berührt.** Sie liest vom
/// Dateisystem und bringt mehrere Megabyte WebAssembly mit; beides hat dort
/// nichts zu suchen. Deshalb wählt nicht `db.ts` die Ausprägung, sondern der
/// Einstiegspunkt — `index.ts` unter Node, `supabase/functions/api/` in der
/// Ferne.

const MIGRATIONEN = join(
  dirname(fileURLToPath(import.meta.url)), "..", "..", "supabase", "migrations");

/// Die Migrationen als ein Text, in ihrer Reihenfolge.
///
/// **Dieselben Dateien, die Supabase anwendet** — nicht eine Kopie daneben. Ein
/// Schema in zwei Fassungen ist ein Schema, das auseinanderläuft, und der
/// Unterschied fiele erst auf, wenn eine Abfrage in der Ferne anders antwortet
/// als in den Tests.
export function schema(): string {
  return readdirSync(MIGRATIONEN)
    .filter((n) => n.endsWith(".sql"))
    .sort()
    .map((n) => readFileSync(join(MIGRATIONEN, n), "utf8"))
    .join("\n");
}

export async function treiber(ordner = ""): Promise<Treiber> {
  const pg = ordner ? new PGlite(ordner) : new PGlite();
  await pg.waitReady;
  return {
    abfrage: async (sql, werte) =>
      (await pg.query(sql, werte as never[])).rows as Zeile[],
    ausfuehren: async (sql) => { await pg.exec(sql); },
    schliesse: async () => { await pg.close(); },
  };
}

/// Öffnen und Schema anlegen in einem Zug — was Tests und der lokale Betrieb
/// wollen. Ohne Ordner: nur im Arbeitsspeicher.
export async function oeffneEingebettet(ordner = ""): Promise<Db> {
  const db = Db.mitTreiber(await treiber(ordner));
  await db.legeSchemaAn(schema());
  return db;
}
