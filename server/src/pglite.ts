import { PGlite } from "@electric-sql/pglite";
import type { Treiber, Zeile } from "./db.ts";

/// Postgres im eigenen Prozess — für Tests und für den Betrieb ohne Server.
///
/// PGlite ist kein Nachbau, sondern dasselbe Postgres nach WebAssembly
/// übersetzt. Deshalb prüfen die Tests denselben Dialekt, dieselben Typen und
/// dieselben Fehlermeldungen wie Supabase, ohne dass ein Container laufen muss.
///
/// **Bewusst eine eigene Datei.** `db.ts` lädt sie erst, wenn sie gebraucht
/// wird; im Bündel einer Edge Function haben mehrere Megabyte WebAssembly
/// nichts zu suchen.
export async function eingebettet(ordner = ""): Promise<Treiber> {
  const pg = ordner ? new PGlite(ordner) : new PGlite();
  await pg.waitReady;
  return {
    abfrage: async (sql, werte) =>
      (await pg.query(sql, werte as never[])).rows as Zeile[],
    ausfuehren: async (sql) => { await pg.exec(sql); },
    schliesse: async () => { await pg.close(); },
  };
}
